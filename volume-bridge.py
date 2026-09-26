#!/usr/bin/env python3
#
# HomePod Spotify Connect - Volume Bridge
#
# Keeps the Spotify Connect volume (go-librespot) and the AirPlay volume
# (OwnTone) in sync, in both directions:
#
#   Spotify slider  -> go-librespot /events -> OwnTone  /api/player/volume
#   OwnTone web UI  -> OwnTone notify ws    -> go-librespot /player/volume
#
# go-librespot runs with external_volume, so it never scales the samples
# itself; the HomePod's own volume is the only volume stage.
#

import asyncio
import json
import logging
import time
import urllib.request

import websockets

GO_LIBRESPOT = "http://127.0.0.1:3678"
OWNTONE = "http://127.0.0.1:3689"
OWNTONE_WS_PORT = 3688

# After pushing a volume to one side, ignore echoes from that side for this long.
# Without it, fast slider moves bounce stale values back and the slider jitters.
ECHO_WINDOW = 1.0

log = logging.getLogger("volume-bridge")

# urllib/socket failures are OSError; bad or unexpected JSON is ValueError/KeyError
HTTP_ERRORS = (OSError, ValueError, KeyError)

last_volume = None          # 0-100, last value both sides agreed on
muted_until = {"spotify": 0.0, "owntone": 0.0}


def http(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


async def push(target, volume):
    global last_volume
    last_volume = volume
    muted_until[target] = time.monotonic() + ECHO_WINDOW
    try:
        if target == "owntone":
            await asyncio.to_thread(http, "PUT", f"{OWNTONE}/api/player/volume?volume={volume}")
        else:
            state = await asyncio.to_thread(http, "GET", f"{GO_LIBRESPOT}/player/volume")
            value = round(volume * state["max"] / 100)
            await asyncio.to_thread(http, "POST", f"{GO_LIBRESPOT}/player/volume", {"volume": value})
        log.info("volume %d%% -> %s", volume, target)
    except HTTP_ERRORS as e:
        # go-librespot rejects volume changes while no Spotify client is connected
        log.debug("could not set %s volume: %s", target, e)


def is_echo(source, volume):
    return volume == last_volume or time.monotonic() < muted_until[source]


async def follow_spotify():
    async with websockets.connect("ws://127.0.0.1:3678/events") as ws:
        log.info("connected to go-librespot")
        async for message in ws:
            event = json.loads(message)
            if event.get("type") != "volume":
                continue
            volume = round(event["data"]["value"] * 100 / event["data"]["max"])
            if not is_echo("spotify", volume):
                await push("owntone", volume)


async def follow_owntone():
    async with websockets.connect(f"ws://127.0.0.1:{OWNTONE_WS_PORT}",
                                  subprotocols=["notify"]) as ws:
        await ws.send(json.dumps({"notify": ["volume"]}))
        log.info("connected to OwnTone")
        async for message in ws:
            if "volume" not in json.loads(message).get("notify", []):
                continue
            player = await asyncio.to_thread(http, "GET", f"{OWNTONE}/api/player")
            volume = player["volume"]
            if not is_echo("owntone", volume):
                await push("spotify", volume)


async def forever(follow):
    while True:
        try:
            await follow()
        except (websockets.WebSocketException, *HTTP_ERRORS) as e:
            log.warning("%s: %s, reconnecting", follow.__name__, e)
        await asyncio.sleep(3)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    await asyncio.gather(forever(follow_spotify), forever(follow_owntone))


if __name__ == "__main__":
    asyncio.run(main())
