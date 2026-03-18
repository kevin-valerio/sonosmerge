#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass


SONOS_SERVICE_TYPE = "_sonos._tcp"
SONOS_SERVICE_DOMAIN = "local."
SOUND_MENU_IDENTIFIER = "com.apple.menuextra.sound"


@dataclass
class Room:
    name: str
    uuid: str
    coordinator_uuid: str
    group_id: str
    host: str
    airplay_enabled: bool


class BroadcastError(Exception):
    pass


def capture_timeout_output(command: list[str], timeout_seconds: float) -> str:
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=True,
        )
        return completed.stdout
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        if isinstance(stdout, bytes):
            return stdout.decode("utf-8", errors="replace")
        return stdout


def discover_sonos_hosts(timeout_seconds: float = 4.0) -> list[str]:
    output = capture_timeout_output(
        ["dns-sd", "-Z", SONOS_SERVICE_TYPE, SONOS_SERVICE_DOMAIN],
        timeout_seconds,
    )
    hosts: set[str] = set()
    location_pattern = re.compile(r'location=(?P<location>http://[^"\s]+)')

    for match in location_pattern.finditer(output):
        parsed_location = urllib.parse.urlparse(match.group("location"))
        if parsed_location.hostname:
            hosts.add(parsed_location.hostname)

    return sorted(hosts)


def soap_request(host: str, path: str, action: str, body: str) -> bytes:
    request = urllib.request.Request(
        url=f"http://{host}:1400{path}",
        data=body.encode("utf-8"),
        headers={
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPACTION": f'"{action}"',
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.read()
    except urllib.error.URLError as error:
        raise BroadcastError(f"Could not reach Sonos host {host}: {error}") from error


def fetch_zone_group_state(host: str) -> ET.Element:
    body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1" />
  </s:Body>
</s:Envelope>
"""
    xml_bytes = soap_request(
        host=host,
        path="/ZoneGroupTopology/Control",
        action="urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState",
        body=body,
    )
    envelope = ET.fromstring(xml_bytes)
    zone_group_state = None
    for element in envelope.iter():
        if element.tag.endswith("ZoneGroupState"):
            zone_group_state = element.text
            break

    if not zone_group_state:
        raise BroadcastError("Could not read Sonos ZoneGroupState from the network response.")

    return ET.fromstring(zone_group_state)


def discover_rooms() -> list[Room]:
    sonos_hosts = discover_sonos_hosts()
    if not sonos_hosts:
        raise BroadcastError("Could not discover any Sonos rooms on the local network.")

    zone_group_state = fetch_zone_group_state(sonos_hosts[0])
    rooms_by_name: dict[str, Room] = {}

    for group in zone_group_state.findall(".//ZoneGroup"):
        coordinator_uuid = group.attrib.get("Coordinator", "")
        group_id = group.attrib.get("ID", "")
        for member in group.findall("./ZoneGroupMember"):
            if member.attrib.get("Invisible") == "1":
                continue

            name = member.attrib.get("ZoneName")
            uuid = member.attrib.get("UUID")
            location = member.attrib.get("Location")
            if not name or not uuid or not location:
                continue

            parsed_location = urllib.parse.urlparse(location)
            if not parsed_location.hostname:
                continue

            rooms_by_name[name] = Room(
                name=name,
                uuid=uuid,
                coordinator_uuid=coordinator_uuid,
                group_id=group_id,
                host=parsed_location.hostname,
                airplay_enabled=member.attrib.get("AirPlayEnabled") == "1",
            )

    if not rooms_by_name:
        raise BroadcastError("Discovered Sonos devices, but no visible rooms were found.")

    return sorted(rooms_by_name.values(), key=lambda room: room.name.lower())


def run_osascript(script: str, environment: dict[str, str]) -> str:
    process = subprocess.run(
        ["osascript"],
        input=script,
        text=True,
        capture_output=True,
        env={**os.environ, **environment},
        check=False,
    )
    if process.returncode != 0:
        stderr = process.stderr.strip() or process.stdout.strip() or "Unknown AppleScript error."
        raise BroadcastError(stderr)
    return process.stdout.strip()


def set_mac_output(room_name: str) -> str:
    applescript = f"""
set targetDeviceName to system attribute "AIRPLAY_TARGET"
set targetIdentifier to "sound-device-" & targetDeviceName
set soundMenuIdentifier to "{SOUND_MENU_IDENTIFIER}"

on listContains(itemList, expectedItem)
\trepeat with itemValue in itemList
\t\tif (contents of itemValue) is expectedItem then return true
\tend repeat
\treturn false
end listContains

on joinList(itemList, separatorText)
\tset joinedText to ""
\trepeat with itemValue in itemList
\t\tif joinedText is not "" then set joinedText to joinedText & separatorText
\t\tset joinedText to joinedText & (contents of itemValue)
\tend repeat
\treturn joinedText
end joinList

on soundPanelIsOpen(controlCenterProcess)
\ttell application "System Events"
\t\ttell controlCenterProcess
\t\t\tif (count of windows) is 0 then return false
\t\t\ttry
\t\t\t\tset deviceCheckboxes to checkboxes of scroll area 1 of group 1 of window 1
\t\t\t\trepeat with checkboxRef in deviceCheckboxes
\t\t\t\t\ttry
\t\t\t\t\t\tset checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
\t\t\t\t\t\tif checkboxIdentifier starts with "sound-device-" then return true
\t\t\t\t\tend try
\t\t\t\tend repeat
\t\t\tend try
\t\tend tell
\tend tell
\treturn false
end soundPanelIsOpen

on targetSelected(controlCenterProcess, targetIdentifier)
\ttell application "System Events"
\t\ttell controlCenterProcess
\t\t\tif (count of windows) is 0 then return false
\t\t\ttry
\t\t\t\tset deviceCheckboxes to checkboxes of scroll area 1 of group 1 of window 1
\t\t\t\trepeat with checkboxRef in deviceCheckboxes
\t\t\t\t\ttry
\t\t\t\t\t\tset checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
\t\t\t\t\t\tif checkboxIdentifier is targetIdentifier then
\t\t\t\t\t\t\treturn (value of checkboxRef) is 1
\t\t\t\t\t\tend if
\t\t\t\t\tend try
\t\t\t\tend repeat
\t\t\tend try
\t\tend tell
\tend tell
\treturn false
end targetSelected

tell application "System Events"
\ttell process "ControlCenter"
\t\tset controlCenterProcess to it
\t\tset soundMenuItem to missing value
\t\trepeat with menuItemRef in every menu bar item of menu bar 1
\t\t\ttry
\t\t\t\tif value of attribute "AXIdentifier" of menuItemRef is soundMenuIdentifier then
\t\t\t\t\tset soundMenuItem to menuItemRef
\t\t\t\t\texit repeat
\t\t\t\tend if
\t\t\tend try
\t\tend repeat
\t\tif soundMenuItem is missing value then error "Could not find the Sound menu bar item in the menu bar."

\t\tif my soundPanelIsOpen(controlCenterProcess) is false then
\t\t\tclick soundMenuItem
\t\tend if

\t\trepeat 20 times
\t\t\tif my soundPanelIsOpen(controlCenterProcess) then exit repeat
\t\t\tdelay 0.1
\t\tend repeat

\t\tif my soundPanelIsOpen(controlCenterProcess) is false then error "Could not open the Sound output panel."

\t\tset availableIdentifiers to {{}}
\t\trepeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
\t\t\ttry
\t\t\t\tset end of availableIdentifiers to (value of attribute "AXIdentifier" of checkboxRef)
\t\t\tend try
\t\tend repeat

\t\tif my listContains(availableIdentifiers, targetIdentifier) is false then
\t\t\terror "Could not find " & targetIdentifier & ". Available outputs: " & my joinList(availableIdentifiers, ", ")
\t\tend if

\t\trepeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
\t\t\ttry
\t\t\t\tset checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
\t\t\t\tif checkboxIdentifier is targetIdentifier then
\t\t\t\t\tif (value of checkboxRef) is not 1 then click checkboxRef
\t\t\t\t\texit repeat
\t\t\t\tend if
\t\t\tend try
\t\tend repeat

\t\trepeat 100 times
\t\t\tif my targetSelected(controlCenterProcess, targetIdentifier) then exit repeat
\t\t\tdelay 0.1
\t\tend repeat

\t\tif my targetSelected(controlCenterProcess, targetIdentifier) is false then
\t\t\terror "Timed out while waiting for " & targetDeviceName & " to switch on."
\t\tend if

\t\trepeat with checkboxRef in checkboxes of scroll area 1 of group 1 of window 1
\t\t\ttry
\t\t\t\tset checkboxIdentifier to value of attribute "AXIdentifier" of checkboxRef
\t\t\t\tif checkboxIdentifier starts with "sound-device-" then
\t\t\t\t\tif checkboxIdentifier is not targetIdentifier then
\t\t\t\t\t\tif (value of checkboxRef) is 1 then click checkboxRef
\t\t\t\t\tend if
\t\t\t\tend if
\t\t\tend try
\t\tend repeat

\t\tdelay 0.2
\t\tif my soundPanelIsOpen(controlCenterProcess) then click soundMenuItem
\tend tell
end tell

return "Mac output switched to: " & targetDeviceName
"""
    return run_osascript(applescript, {"AIRPLAY_TARGET": room_name})


def join_room_to_coordinator(joiner_room: Room, coordinator_uuid: str) -> None:
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>x-rincon:{coordinator_uuid}</CurrentURI>
      <CurrentURIMetaData></CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>
"""
    soap_request(
        host=joiner_room.host,
        path="/MediaRenderer/AVTransport/Control",
        action="urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI",
        body=body,
    )


def broadcast(room_names: list[str]) -> dict[str, object]:
    if not room_names:
        raise BroadcastError("Pick at least one room to broadcast.")

    discovered_rooms = discover_rooms()
    rooms_by_name = {room.name: room for room in discovered_rooms}
    missing_rooms = [room_name for room_name in room_names if room_name not in rooms_by_name]

    if missing_rooms:
        available_names = ", ".join(room.name for room in discovered_rooms)
        raise BroadcastError(
            "Could not find the selected Sonos rooms: "
            + ", ".join(missing_rooms)
            + f". Available rooms: {available_names}"
        )

    selected_rooms = [rooms_by_name[room_name] for room_name in room_names]
    airplay_target = next((room for room in selected_rooms if room.airplay_enabled), None)
    if airplay_target is None:
        raise BroadcastError("None of the selected rooms can be used as the Mac AirPlay target.")

    mac_output_message = set_mac_output(airplay_target.name)

    joined_room_names: list[str] = []
    for room in selected_rooms:
        if room.name == airplay_target.name:
            continue
        if room.coordinator_uuid == airplay_target.coordinator_uuid:
            continue
        join_room_to_coordinator(room, airplay_target.coordinator_uuid)
        joined_room_names.append(room.name)

    return {
        "selected_rooms": room_names,
        "airplay_target": airplay_target.name,
        "joined_rooms": joined_room_names,
        "message": mac_output_message,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Broadcast Mac audio to a Sonos room group.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("discover", help="List visible Sonos rooms as JSON.")

    broadcast_parser = subparsers.add_parser("broadcast", help="Switch Mac audio and group selected Sonos rooms.")
    broadcast_parser.add_argument("--rooms", nargs="+", required=True, help="Visible Sonos room names.")
    broadcast_parser.add_argument("--json", action="store_true", help="Print the broadcast result as JSON.")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.command == "discover":
            rooms = [asdict(room) for room in discover_rooms()]
            print(json.dumps({"rooms": rooms}, indent=2))
            return 0

        if args.command == "broadcast":
            result = broadcast(args.rooms)
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print(
                    f"Mac output switched to {result['airplay_target']}, "
                    f"and these rooms joined that Sonos room: {', '.join(result['joined_rooms']) or 'none'}."
                )
            return 0

    except BroadcastError as error:
        print(str(error), file=sys.stderr)
        return 1

    parser.error("Unsupported command.")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
