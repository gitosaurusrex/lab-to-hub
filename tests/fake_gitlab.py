"""A stand-in for the parts of the GitLab REST API the scripts use.

Usage: fake_gitlab.py <state.json> <port-file>

The state file holds {"groups": [...], "projects": [...]}. A group may set
"fail_page" to make that page of its project listing return a 500. Like
GitLab, pages hold at most MAX_PER_PAGE items whatever per_page asks for.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TOKEN = "secret-token"
MAX_PER_PAGE = 10
KNOWN_PARAMS = {"per_page", "page", "order_by", "sort", "archived"}

state_path, port_path = sys.argv[1], sys.argv[2]
with open(state_path) as f:
    state = json.load(f)


def save():
    with open(state_path, "w") as f:
        json.dump(state, f, indent=2)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def route(self, method):
        if self.headers.get("PRIVATE-TOKEN") != TOKEN:
            return self.reply(401, {"message": "401 Unauthorized"})
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        unknown = set(query) - KNOWN_PARAMS
        if unknown:
            return self.reply(400, {"error": f"unknown parameters {sorted(unknown)}"})
        parts = url.path.removeprefix("/api/v4/").split("/")
        page = int(query.get("page", ["1"])[0])
        per_page = min(int(query.get("per_page", ["20"])[0]), MAX_PER_PAGE)

        def paginate(items):
            return self.reply(200, items[(page - 1) * per_page : page * per_page])

        if method == "GET" and parts == ["groups"]:
            return paginate(state["groups"])
        if method == "GET" and len(parts) == 3 and parts[0] == "groups" and parts[2] == "projects":
            group = next((g for g in state["groups"] if str(g["id"]) == parts[1]), None)
            if group is None:
                return self.reply(404, {"message": "404 Group Not Found"})
            if group.get("fail_page") == page:
                return self.reply(500, {"message": "500 Internal Server Error"})
            projects = [p for p in state["projects"] if p["namespace"]["id"] == group["id"]]
            if query.get("archived") == ["false"]:
                projects = [p for p in projects if not p["archived"]]
            return paginate(projects)
        if parts[0] == "projects" and len(parts) >= 2:
            project = next((p for p in state["projects"] if str(p["id"]) == parts[1]), None)
            if project is None:
                return self.reply(404, {"message": "404 Project Not Found"})
            if method == "GET" and len(parts) == 2:
                return self.reply(200, project)
            if method == "POST" and parts[2:] == ["archive"]:
                project["archived"] = True
                save()
                return self.reply(201, project)
        return self.reply(404, {"message": "404 Not Found"})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
