#!/bin/bash
# Applies a changed sync_list: the OneDrive client refuses to run until it has
# done one --resync after the list changes. The widget's "Apply" button runs
# this in a visible terminal, so progress and any question are on screen.
#
# Usage: resync.sh [--confdir DIR] [--service NAME] [--scope user]

set -u
confdir="" service="onedrive" scope="user"
while (($#)); do
  case $1 in
    --confdir) confdir=${2:-}; shift 2 ;;
    --service) service=${2:-onedrive}; shift 2 ;;
    --scope) scope=${2:-user}; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ $scope != user ]]; then
  echo "This only works for a OneDrive client running as a user service." >&2
  exit 1
fi
if [[ ! $service =~ ^[A-Za-z0-9@_.:-]{1,128}$ ]]; then
  echo "Invalid service name." >&2
  exit 1
fi
[[ $service == *.service ]] || service+=".service"

client_args=()
config_dir=${XDG_CONFIG_HOME:-$HOME/.config}/onedrive
if [[ -n $confdir ]]; then
  config_dir=$confdir
  client_args=(--confdir "$confdir")
fi

# The same rule as folders.py's is_folder_line: a path, not a wildcard or "//" comment.
folder_lines() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$config_dir/sync_list" 2>/dev/null |
    grep -E '^/' | grep -vE '^/(\*|/)' | grep -vF '*'
}

if [[ -z $(folder_lines) ]]; then
  echo "No folders are selected, which would sync the whole OneDrive. Nothing was changed." >&2
  exit 1
fi

echo "Updating which OneDrive folders sync to this laptop."
echo
echo "Folders now selected:"
folder_lines | sed 's/^/  /'
echo
echo "Stopping background sync…"
systemctl --user stop "$service"

echo "Resyncing (new folders download now; this can take a few minutes)…"
echo
if onedrive "${client_args[@]}" --sync --resync --resync-auth; then
  status=done
else
  status=failed
fi

echo
echo "Starting background sync again…"
systemctl --user start "$service"
# The widget's IPC name, as Panel.qml builds it from the service name.
service_name=${service%.service}
if [[ $service_name == onedrive ]]; then
  ipc_target=gittyio.onedrive
else
  ipc_target=gittyio.onedrive.${service_name//[^A-Za-z0-9_-]/-}
fi
omarchy-shell -q "$ipc_target" refresh

echo
if [[ $status == done ]]; then
  echo "All set. You can close this window."
  notify-send -a OneDrive "OneDrive folders updated" "Your folder selection is now syncing." 2>/dev/null
else
  echo "The resync reported a problem (see above). Background sync was restarted anyway."
  echo "Open the OneDrive widget's sync log for details."
fi
echo
