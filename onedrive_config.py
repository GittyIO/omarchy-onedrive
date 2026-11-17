"""Shared helpers: where the OneDrive Client for Linux keeps its files, and what it is set to.

Every helper script takes the same three options so one widget can follow any
client setup, including a second account with its own --confdir and unit:

  --confdir DIR      the client's config directory (default ~/.config/onedrive)
  --service NAME     its systemd unit (default onedrive)
  --scope user|system  whether that unit is a user or a system service
"""

import argparse
import os
import re

DEFAULT_APP_ID = "d50ca740-c83f-4d1b-b616-12c519384f0c"  # the client's own app registration


def default_confdir():
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "onedrive")


def add_common_args(parser):
    parser.add_argument("--confdir", default="")
    parser.add_argument("--service", default="onedrive")
    parser.add_argument("--scope", choices=["user", "system"], default="user")


def resolve(args):
    """Normalise the common options; raise ValueError on anything unsafe."""
    confdir = os.path.realpath(os.path.expanduser(args.confdir or default_confdir()))
    service = args.service or "onedrive"
    if not re.fullmatch(r"[A-Za-z0-9@_.:\\-]{1,128}", service):
        raise ValueError("Invalid service name.")
    if not service.endswith((".service",)):
        service += ".service"
    return confdir, service, args.scope


def read_config(confdir):
    """The client's config file as a dict of plain key = value pairs."""
    values = {}
    try:
        with open(os.path.join(confdir, "config"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def sync_dir(confdir):
    path = read_config(confdir).get("sync_dir") or "~/OneDrive"
    return os.path.realpath(os.path.expanduser(path))


def is_default_confdir(confdir):
    return os.path.realpath(confdir) == os.path.realpath(default_confdir())


def systemctl(scope):
    return ["systemctl", "--user"] if scope == "user" else ["systemctl"]


def journalctl(scope):
    return ["journalctl", "--user"] if scope == "user" else ["journalctl"]


def parser(description):
    p = argparse.ArgumentParser(description=description)
    add_common_args(p)
    return p
