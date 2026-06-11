import requests
import json

RPC_URL = "http://127.0.0.1:14022/"
RPC_AUTH = ("user", "pass")

def rpc(method, params=None):
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or []
    }
    r = requests.post(RPC_URL, auth=RPC_AUTH, json=payload)
    return r.json()["result"]
