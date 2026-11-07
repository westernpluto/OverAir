#!/usr/bin/env python3
"""A mock HDHomeRun FLEX 4K + SiliconDust cloud API for simulator screenshots and CI.

Serves discover/lineup/status JSON, live MPEG-TS streams (looped test clips, paced in real time),
guide data, DVR rules and recordings. Usage: mock_hdhomerun.py <media-dir> [port]
"""
import json, os, sys, time, threading, random
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

MEDIA = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5004
BASE = f"http://127.0.0.1:{PORT}"

CHANNELS = [
    ("2.1", "CBS2-HD", "1080i", "CBS"), ("4.1", "NBC4-HD", "720p", "NBC"), ("5.1", "FOX5", "720p", "FOX"),
    ("7.1", "ABC7-HD", "1080i", "ABC"), ("9.1", "MeTV", "480i", "MeTV"), ("11.1", "PBS-HD", "1080i", "PBS"),
    ("13.1", "UniMas", "480i", "UNI"), ("20.1", "CW", "1080i", "CW"), ("26.1", "H&I", "480i", "HI"),
    ("32.1", "ION", "720p", "ION"),
]
FAVORITE = {"2.1", "4.1", "7.1"}

SHOWS = [
    ("Evening News", ["News"]), ("Morning Show", ["News", "Talk"]), ("The Big Game", ["Sports"]),
    ("Monday Night Football", ["Sports"]), ("Chef's Table Live", ["Cooking"]), ("Nature Untamed", ["Documentary", "Nature"]),
    ("City Detectives", ["Drama", "Crime"]), ("Laugh Track", ["Comedy"]), ("Saturday Movie: Starfall", ["Movies", "Action"]),
    ("Kids Club", ["Kids"]), ("Wheel of Prizes", ["Game Show"]), ("Late Night Talk", ["Talk"]),
    ("Home Makeover", ["Home & Garden", "Reality"]), ("Classic Westerns", ["Western"]), ("Science Now", ["Science"]),
]

def guide(start):
    now = int(time.time())
    slot = now - now % 1800 - 1800
    out = []
    rng = random.Random(7)
    for num, name, fmt, aff in CHANNELS:
        progs = []
        t = slot
        i = 0
        while t < slot + 6 * 3600:
            title, filt = SHOWS[(hash(num) + i) % len(SHOWS)] if False else SHOWS[(int(float(num) * 10) + i * 3) % len(SHOWS)]
            dur = 3600 if "Movie" in title or "Football" in title or "Game" in title else 1800
            sid = "S%05d" % (abs(hash(title)) % 100000)
            progs.append({
                "StartTime": t, "EndTime": t + dur, "Title": title,
                "EpisodeNumber": "S%02dE%02d" % (rng.randint(1, 9), rng.randint(1, 22)) if "Movie" not in title else None,
                "EpisodeTitle": rng.choice(["Pilot", "The Return", "Homecoming", "Breaking Point", "Finale", None]),
                "Synopsis": f"{title} on {name}. A sample program from the OverAir test server.",
                "ImageURL": f"{BASE}/art/{(int(float(num)*10)+i)%6}.jpg",
                "SeriesID": sid, "Filter": filt, "First": 1 if i % 4 == 0 else 0,
                "OriginalAirdate": t - 86400 * 30,
            })
            t += dur
            i += 1
        out.append({"GuideNumber": num, "GuideName": name, "Affiliate": aff, "ImageURL": f"{BASE}/logo/{num}.png", "Guide": progs})
    return out

def lineup():
    return [{"GuideNumber": n, "GuideName": nm, "VideoCodec": "MPEG2", "AudioCodec": "AC3", "HD": 1 if f != "480i" else 0,
             "Favorite": 1 if n in FAVORITE else 0, "URL": f"{BASE}/auto/v{n}"} for n, nm, f, _ in CHANNELS]

def discover():
    return {"FriendlyName": "HDHomeRun FLEX 4K", "ModelNumber": "HDFX-4K", "FirmwareName": "hdhomerun_dvr_atsc3",
            "FirmwareVersion": "20261015", "DeviceID": "10ABCDEF", "DeviceAuth": "mockdeviceauth", "BaseURL": BASE,
            "LineupURL": f"{BASE}/lineup.json", "TunerCount": 4, "StorageID": "10ABCDEF-DVR",
            "StorageURL": f"{BASE}/recorded_files.json", "TotalSpace": 2000000000000, "FreeSpace": 1340000000000}

ACTIVE = {}
def status():
    out = []
    for i in range(4):
        ch = ACTIVE.get(i)
        if ch:
            out.append({"Resource": f"tuner{i}", "VctNumber": ch, "VctName": dict((c[0], c[1]) for c in CHANNELS)[ch],
                        "Frequency": 503000000 + i * 6000000, "SignalStrengthPercent": 92, "SignalQualityPercent": 88,
                        "SymbolQualityPercent": 100, "NetworkRate": 9800000, "TargetIP": "127.0.0.1"})
        else:
            out.append({"Resource": f"tuner{i}"})
    return out

RULES = [{"RecordingRuleID": "101", "SeriesID": "S00001", "Title": "City Detectives", "Synopsis": "Weekly crime drama.",
          "ImageURL": f"{BASE}/art/2.jpg", "StartPadding": 30, "EndPadding": 120, "Priority": 2},
         {"RecordingRuleID": "102", "SeriesID": "S00002", "Title": "Nature Untamed", "RecentOnly": 1,
          "ImageURL": f"{BASE}/art/4.jpg", "StartPadding": 30, "EndPadding": 60, "Priority": 1}]

def recorded():
    return [{"SeriesID": "S00001", "Title": "City Detectives", "Category": "series", "ImageURL": f"{BASE}/art/2.jpg",
             "StartTime": int(time.time()) - 86400, "EpisodesURL": f"{BASE}/recorded_files.json?SeriesID=S00001"},
            {"SeriesID": "S00002", "Title": "Nature Untamed", "Category": "series", "ImageURL": f"{BASE}/art/4.jpg",
             "StartTime": int(time.time()) - 3 * 86400, "EpisodesURL": f"{BASE}/recorded_files.json?SeriesID=S00002"},
            {"SeriesID": "S00003", "Title": "Saturday Movie: Starfall", "Category": "movie", "ImageURL": f"{BASE}/art/5.jpg",
             "StartTime": int(time.time()) - 5 * 86400, "EpisodesURL": f"{BASE}/recorded_files.json?SeriesID=S00003"}]

def episodes(sid):
    now = int(time.time())
    out = []
    for k in range(3):
        st = now - (k + 1) * 86400
        out.append({"ProgramID": f"{sid}-{k}", "SeriesID": sid, "Title": {"S00001": "City Detectives", "S00002": "Nature Untamed"}.get(sid, "Saturday Movie: Starfall"),
                    "EpisodeNumber": f"S02E{10-k:02d}", "EpisodeTitle": ["Breaking Point", "Homecoming", "The Return"][k],
                    "Synopsis": "A recorded episode from the test server.", "ImageURL": f"{BASE}/art/{k+1}.jpg",
                    "ChannelNumber": "7.1", "ChannelName": "ABC7-HD", "RecordStartTime": st, "RecordEndTime": st + 1800,
                    "StartTime": st, "EndTime": st + 1800, "Resume": 600 if k == 0 else 0,
                    "PlayURL": f"{BASE}/recorded/play?id={sid}{k}", "CmdURL": f"{BASE}/recorded/cmd?id={sid}{k}"})
    return out

def media_for(channel):
    fmt = dict((c[0], c[2]) for c in CHANNELS).get(channel, "1080i")
    return os.path.join(MEDIA, f"{fmt}.ts")

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length: self.rfile.read(length)
        self.send_json({})

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path
        if p == "/discover.json": return self.send_json(discover())
        if p == "/lineup.json": return self.send_json(lineup())
        if p == "/status.json": return self.send_json(status())
        if p == "/lineup_status.json": return self.send_json({"ScanInProgress": 0, "ScanPossible": 1, "Source": "Antenna", "SourceList": ["Antenna"]})
        if p == "/discover": return self.send_json([])
        if p in ("/api/guide", "/api/guide.php"):
            start = int(q.get("Start", [time.time()])[0])
            return self.send_json(guide(start) if start < time.time() + 3600 else [])
        if p == "/api/recording_rules": return self.send_json(RULES)
        if p == "/api/search":
            term = q.get("Search", [""])[0].lower()
            return self.send_json([{"SeriesID": "S%05d" % (abs(hash(t)) % 100000), "Title": t, "Synopsis": f"{t} on broadcast TV.",
                                    "ImageURL": f"{BASE}/art/1.jpg"} for t, _ in SHOWS if term in t.lower()])
        if p == "/api/episodes": return self.send_json([])
        if p == "/recorded_files.json":
            sid = q.get("SeriesID", [None])[0]
            return self.send_json(episodes(sid) if sid else recorded())
        if p.startswith("/art/") or p.startswith("/logo/"):
            name = "logo.png" if p.startswith("/logo/") else "art%s.jpg" % (int(p.split("/")[-1].split(".")[0]) % 6)
            path = os.path.join(MEDIA, name)
            if os.path.exists(path):
                data = open(path, "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", "image/png" if name.endswith("png") else "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_error(404); return
        if p.startswith("/auto/v"):
            return self.stream(p[len("/auto/v"):], live=True)
        if p == "/recorded/play":
            return self.stream("7.1", live=False)
        self.send_error(404)

    def stream(self, channel, live):
        path = media_for(channel)
        data = open(path, "rb").read()
        tuner = next((i for i in range(4) if i not in ACTIVE), None)
        if tuner is None:
            self.send_error(503, "All tuners in use"); return
        ACTIVE[tuner] = channel
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Connection", "close")
        if not live: self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            rate = 1_500_000 if live else 50_000_000  # bytes per second
            chunk = 188 * 300
            loops = 50 if live else 1
            for _ in range(loops):
                for i in range(0, len(data), chunk):
                    self.wfile.write(data[i:i + chunk])
                    if live: time.sleep(chunk / rate)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            ACTIVE.pop(tuner, None)

if __name__ == "__main__":
    print(f"mock HDHomeRun on {BASE}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
