#!/bin/bash
set -euo pipefail

# Argument guards
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <pixels> <screen width offset> <window x position offset>"
  echo "          Only <pixels> is required"
  exit 1
fi

PIXELS=$1
if ! [[ "$PIXELS" =~ ^-?[0-9]+$ ]]; then
  echo "Pixels must be a number"
  echo "Usage: $0 <pixels> <screen width offset> <window x position offset>"
  echo "          Only <pixels> is required"
  exit 1
fi

SCREEN_WIDTH_OFFSET="${2:-40}" # Second argument
WINDOW_OFFSET="${3:-20}"
start_time=$(date +%s%3N)


# Lock file to prevent parallel execution
LOCKFILE="/var/lock/resize.lock"
RETRIES=5
SLEEP_INTERVAL=0.1
CACHE_FILE="/tmp/screen_info.cache"
CACHE_EXPIRY=900 # 15 minutes in seconds
RESIZE_WITH_RIGHT_BUTTON_PREFERENCE=$(gsettings get org.gnome.desktop.wm.preferences resize-with-right-button)
MOUSE_MODIFIER_BUTTON_PREFERENCE=$(gsettings get org.gnome.desktop.wm.preferences mouse-button-modifier | sed "s/[<>\']//g")
RESIZE_MOUSE_BUTTON=2
if [ "$RESIZE_WITH_RIGHT_BUTTON_PREFERENCE" == "true" ]; then
  RESIZE_MOUSE_BUTTON=3
fi

echo "RESIZE_WITH_RIGHT_BUTTON_PREFERENCE $RESIZE_WITH_RIGHT_BUTTON_PREFERENCE mouse button $RESIZE_MOUSE_BUTTON"
exec 200>$LOCKFILE
flock -w 1 200 || { echo "Another instance is running. Exiting."; >>/tmp/resize.log; exit 1; }

# Store original mouse pointer location to restore later
mouse_location=$(xdotool getmouselocation --shell)
eval "$mouse_location"
ORIGINAL_X=$X
ORIGINAL_Y=$Y

# Get active window ID
WINDOW_ID=$(xdotool getactivewindow)

# Get its geometry
window_geometry=$(xdotool getwindowgeometry --shell $WINDOW_ID)
eval "$window_geometry"
WINDOW_START_X=$((X + WINDOW_OFFSET))
WINDOW_START_Y=$((Y + WINDOW_OFFSET))
WINDOW_WIDTH=$WIDTH
WINDOW_HEIGHT=$HEIGHT
WINDOW_END_X=$((WINDOW_START_X + WINDOW_WIDTH))

# Function to get screen info and cache it
get_screen_info() {
  if [[ -f $CACHE_FILE ]]; then
    local cache_mtime=$(stat -c %Y "$CACHE_FILE")
    local current_time=$(date +%s)
    local cache_age=$((current_time - cache_mtime))

    if [[ $cache_age -le $CACHE_EXPIRY ]]; then
      cat "$CACHE_FILE"
      return
    fi
  fi

  xrandr --query | grep ' connected' > "$CACHE_FILE"
  cat "$CACHE_FILE"
}


SCREEN_INFO=$(get_screen_info)


declare -A SCREEN_DIMENSIONS

while IFS= read -r line; do
  SCREEN_NAME=$(echo $line | awk '{print $1}')
  GEOMETRY=$(echo $line | awk '{print $3}')

  # Handle "primary" screen
  if [[ "$GEOMETRY" == "primary" ]]; then
    GEOMETRY=$(echo $line | awk '{print $4}')
  fi

  if [[ "$GEOMETRY" =~ [0-9]+x[0-9]+\+[0-9]+\+[0-9]+ ]]; then
    GEOMETRY=$(echo $GEOMETRY | sed 's/[x+]/ /g')
    read -r WIDTH HEIGHT X_POS Y_POS <<< "$GEOMETRY"
    SCREEN_DIMENSIONS[$SCREEN_NAME]="WIDTH=$((WIDTH + SCREEN_WIDTH_OFFSET)) HEIGHT=$HEIGHT X_POS=$X_POS Y_POS=$Y_POS"
  fi
done <<< "$SCREEN_INFO"

is_point_in_rectangle() {
  local x=$1
  local y=$2
  local rect_x=$3
  local rect_y=$4
  local rect_width=$5
  local rect_height=$6

  local rect_x2=$((rect_x + rect_width))
  local rect_y2=$((rect_y + rect_height))

  if [ "$x" -ge "$rect_x" ] && [ "$x" -le "$rect_x2" ] && [ "$y" -ge "$rect_y" ] && [ "$y" -le "$rect_y2" ]; then
    return 0  # true
  else
    return 1  # false
  fi
}

find_nearest_corner() {
  local small_x=$1
  local small_y=$2
  local small_width=$3
  local small_height=$4

  local rect_x=$5
  local rect_y=$6
  local rect_width=$7
  local rect_height=$8

  local large_x2=$((rect_x + rect_width))
  local large_y2=$((rect_y + rect_height))
  local small_x2=$((small_x + small_width))
  local small_y2=$((small_y + small_height))

  local top_left_distance=$(( (small_x - rect_x) * (small_x - rect_x) + (small_y - rect_y) * (small_y - rect_y) ))
  local top_right_distance=$(( (small_x2 - large_x2) * (small_x2 - large_x2) + (small_y - rect_y) * (small_y - rect_y) ))
  local bottom_left_distance=$(( (small_x - rect_x) * (small_x - rect_x) + (small_y2 - large_y2) * (small_y2 - large_y2) ))
  local bottom_right_distance=$(( (small_x2 - large_x2) * (small_x2 - large_x2) + (small_y2 - large_y2) * (small_y2 - large_y2) ))

  local nearest_corner="top_left"
  local min_distance=$top_left_distance

  if [ $top_right_distance -lt $min_distance ]; then
    nearest_corner="top_right"
    min_distance=$top_right_distance
  fi

  if [ $bottom_left_distance -lt $min_distance ]; then
    nearest_corner="bottom_left"
    min_distance=$bottom_left_distance
  fi

  if [ $bottom_right_distance -lt $min_distance ]; then
    nearest_corner="bottom_right"
  fi

  echo $nearest_corner
}
OFFSET=$(( (2 * WINDOW_OFFSET) ))
for SCREEN in "${!SCREEN_DIMENSIONS[@]}"; do
  eval ${SCREEN_DIMENSIONS[$SCREEN]}

  if is_point_in_rectangle $WINDOW_START_X $WINDOW_START_Y $X_POS $Y_POS $WIDTH $HEIGHT; then

    nearest_corner=$(find_nearest_corner $WINDOW_START_X $WINDOW_START_Y $WINDOW_WIDTH $WINDOW_HEIGHT $X_POS $Y_POS $WIDTH $HEIGHT)
    SCREEN_END_X=$(( X_POS + WIDTH ))

    case $nearest_corner in
      top_left)
        MOUSE_TARGET_X=$((WINDOW_END_X - (3 * OFFSET)))
        MOUSE_TARGET_Y=$(((WINDOW_START_Y + WINDOW_HEIGHT /2) - OFFSET)) #change this to support verticals
        PIXELS_X=$PIXELS
        PIXELS_Y=$PIXELS
        MOVEMENT_DIRECTION_X="right"

        NEW_WINDOW_START_X=$WINDOW_START_X
        NEW_WINDOW_END_X=$((WINDOW_END_X + PIXELS))

        if [ $NEW_WINDOW_END_X -gt $SCREEN_END_X ]; then
          echo "Window will overflow to the right by $(( NEW_WINDOW_END_X - SCREEN_END_X )) pixels"
          PIXELS_X=$((PIXELS - (NEW_WINDOW_END_X - SCREEN_END_X)))
          echo "Window will only be moved $PIXELS_X to the right"
        fi

        ;;
      top_right)
        MOUSE_TARGET_X=$((WINDOW_START_X + OFFSET))
        MOUSE_TARGET_Y=$(((WINDOW_START_Y + WINDOW_HEIGHT /2) - OFFSET))
        PIXELS_X=$(( -PIXELS ))
        PIXELS_Y=$PIXELS
        MOVEMENT_DIRECTION_X="left"

        NEW_WINDOW_START_X=$((WINDOW_START_X - PIXELS))
        NEW_WINDOW_END_X=$((NEW_WINDOW_START_X + PIXELS + WINDOW_WIDTH))

        if [ $NEW_WINDOW_START_X -lt $X_POS ]; then
          PIXELS_X=$((X_POS - WINDOW_START_X))
          echo "Window will only be moved $PIXELS_X to the left"
        fi
        if [ $NEW_WINDOW_END_X -gt $SCREEN_END_X ]; then
          PIXELS_X=$((SCREEN_END_X - WINDOW_WIDTH - WINDOW_START_X))
        fi

        ;;
      bottom_left)
        MOUSE_TARGET_X=$((WINDOW_END_X - (3 * OFFSET)))
        MOUSE_TARGET_Y=$(((WINDOW_START_Y + WINDOW_HEIGHT /2) - OFFSET))
        PIXELS_X=$PIXELS
        PIXELS_Y=$(( -PIXELS ))
        MOVEMENT_DIRECTION_X="right"

        NEW_WINDOW_START_X=$WINDOW_START_X
        NEW_WINDOW_END_X=$((WINDOW_END_X + PIXELS_X))
        if [ $NEW_WINDOW_END_X -gt $SCREEN_END_X ]; then
          PIXELS_X=$((PIXELS - (NEW_WINDOW_END_X - SCREEN_END_X)))
        fi

        ;;
      bottom_right)
        MOUSE_TARGET_X=$((WINDOW_START_X + OFFSET))
        MOUSE_TARGET_Y=$(((WINDOW_START_Y + WINDOW_HEIGHT /2) - OFFSET))
        PIXELS_X=$(( -PIXELS ))
        PIXELS_Y=$(( -PIXELS ))
        MOVEMENT_DIRECTION_X="left"

        NEW_WINDOW_START_X=$((WINDOW_START_X - PIXELS))
        NEW_WINDOW_END_X=$((NEW_WINDOW_START_X + PIXELS + WINDOW_WIDTH))

        if [ $NEW_WINDOW_START_X -lt $X_POS ]; then
          PIXELS_X=$((X_POS - WINDOW_START_X))
        fi
        if [ $NEW_WINDOW_END_X -gt $SCREEN_END_X ]; then
          PIXELS_X=$((SCREEN_END_X - WINDOW_WIDTH - WINDOW_START_X))
        fi

        ;;
    esac

    break
  fi
done

# Fatal error handling
if [ $PIXELS_X -eq 0 ]; then
  echo "Cannot expand anymore"
  window_geometry=$(xdotool getwindowgeometry --shell $WINDOW_ID)
  eval "$window_geometry"
  echo "Window geometry $window_geometry"
  echo "Screen geometry $X_POS $Y_POS $WIDTH $HEIGHT"
  exit 0;
fi

if [ -z "${MOUSE_TARGET_X:-}" ] || [ -z "${MOUSE_TARGET_Y:-}" ]; then
  echo "Error: MOUSE_TARGET_X or MOUSE_TARGET_Y is not set."
  exit 1
fi
echo "MOUSE_TARGET_X: $MOUSE_TARGET_X - WINDOW_START_X: $WINDOW_START_X, WINDOW_END_X: $WINDOW_END_X"
if [ $MOUSE_TARGET_X -lt $WINDOW_START_X ]; then
  echo "Error: Target X is outside window geometry! window starts at $WINDOW_START_X, target is $MOUSE_TARGET_X"
  exit 1;
fi

if [ $MOUSE_TARGET_X -gt $((WINDOW_END_X)) ]; then
  echo "Error: Target X is outside window geometry! window ends at $WINDOW_END_X, target is $MOUSE_TARGET_X"
  exit 1;
fi

if [ -z "${PIXELS_X:-}" ] || [ -z "${PIXELS_Y:-}" ]; then
  echo "Error: PIXELS_X or PIXELS_Y is not set."
  exit 1
fi

NEW_WINDOW_WIDTH=$(( NEW_WINDOW_END_X - NEW_WINDOW_START_X))
echo "Pixels: $PIXELS NEW_WINDOW_WIDTH: $NEW_WINDOW_WIDTH WINDOW_WIDTH: $WINDOW_WIDTH"
if [ $PIXELS -gt 0 ] && [ $NEW_WINDOW_WIDTH -lt $WINDOW_WIDTH ]; then
  echo "[nearest corner: $nearest_corner] It was supposed to grow window but new size is smaller (movement was going to be $PIXELS_X ($MOVEMENT_DIRECTION_X)"
  echo "Original Window geometry x: $X, x_end: $(( X + WIDTH)) width: $WIDTH"
  echo "Wanted window geometry x_start: $NEW_WINDOW_START_X, x_end: $NEW_WINDOW_END_X (width: $NEW_WINDOW_WIDTH)"
  exit 1;
fi

if [ $PIXELS -lt 0 ] && [ $NEW_WINDOW_WIDTH -gt $WINDOW_WIDTH ]; then
  echo "[nearest corner: $nearest_corner] It was supposed to shrink window but new size is larger (movement was going to be $PIXELS_X ($MOVEMENT_DIRECTION_X)"
  echo "Original Window geometry x_start: $X, x_end: $(( X + WIDTH)) width: $WIDTH"
  echo "Wanted window geometry x_start: $NEW_WINDOW_START_X, x_end: $NEW_WINDOW_END_X (width: $NEW_WINDOW_WIDTH)"
  exit 1;
fi


echo "[nearest corner: $nearest_corner] Moving $PIXELS_X horizontal" >> /tmp/resize.log
SLEEP_TIME=0.02

xdotool mousemove $MOUSE_TARGET_X $MOUSE_TARGET_Y
xdotool keydown $MOUSE_MODIFIER_BUTTON_PREFERENCE
sleep $SLEEP_TIME
xdotool mousedown $RESIZE_MOUSE_BUTTON
xdotool mousemove_relative -- "$PIXELS_X" 0
xdotool mouseup $RESIZE_MOUSE_BUTTON
sleep $SLEEP_TIME
xdotool keyup $MOUSE_MODIFIER_BUTTON_PREFERENCE
sleep $SLEEP_TIME
xdotool mousemove $ORIGINAL_X $ORIGINAL_Y

window_geometry=$(xdotool getwindowgeometry --shell $WINDOW_ID)
eval "$window_geometry"
echo "Wanted window geometry $NEW_WINDOW_START_X $NEW_WINDOW_WIDTH"
echo "New Window geometry $X $WIDTH"
end_time=$(date +%s%3N)
echo "Total time: $((end_time - start_time)) ms"
