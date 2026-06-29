#!/usr/bin/env python3
"""
KubeVirt console key injector — connects to a VMI's serial console via WebSocket
and sends a keypress when it detects the "Press any key" prompt from Windows ISO boot.

Usage:
  python3 key_injector.py --vmi win11-test-01 --namespace virt-windows --kubeconfig /path/to/kubeconfig
"""

import argparse
import base64
import json
import sys
import time
import urllib.request
import urllib.error
import ssl

# Try to import websocket; fall back to raw approach
try:
    import websocket  # pip install websocket-client
    HAS_WEBSOCKET = True
except ImportError:
    HAS_WEBSOCKET = False


def get_token(kubeconfig: str) -> str:
    """Extract service account or user token from kubeconfig."""
    import yaml
    try:
        import yaml
    except ImportError:
        # Fallback: grep for token
        import subprocess
        result = subprocess.run(
            ["grep", "-oP", r"(?<=token: )\S+", kubeconfig],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return result.stdout.strip()
        raise RuntimeError(f"Cannot extract token from {kubeconfig} and PyYAML not available")

    with open(kubeconfig) as f:
        kc = yaml.safe_load(f)

    # Try user token first
    for user in kc.get("users", []):
        user_info = user.get("user", {})
        token = user_info.get("token")
        if token:
            return token
        token_file = user_info.get("token-file")
        if token_file:
            with open(token_file) as tf:
                return tf.read().strip()

    # Try service account token
    for ns in kc.get("preferences", {}).get("extensions", []):
        pass  # skip extensions

    # Last resort: get a token via the API itself (SA)
    # Use default service account token
    for cluster_name in kc.get("clusters", []):
        pass  # we just need any token

    # Try to read from SA token file
    try:
        with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
            return f.read().strip()
    except FileNotFoundError:
        pass

    raise RuntimeError("No token found in kubeconfig or SA token file")


def get_server_url(kubeconfig: str) -> str:
    """Extract API server URL from kubeconfig."""
    import yaml
    with open(kubeconfig) as f:
        kc = yaml.safe_load(f)
    for cluster in kc.get("clusters", []):
        return cluster["cluster"]["server"]
    raise RuntimeError("No cluster found in kubeconfig")


def inject_key(kubeconfig: str, vmi_name: str, namespace: str, timeout: int = 180):
    """Connect to VMI console and inject a keypress."""
    api_server = get_server_url(kubeconfig)
    token = get_token(kubeconfig)

    # Console WebSocket URL
    ws_url = f"{api_server}/api/v1/namespaces/{namespace}/virtualmachineinstances/{vmi_name}/console"
    ws_url = ws_url.replace("https://", "wss://").replace("http://", "ws://")

    print(f"Connecting to console WebSocket: {ws_url}")
    print(f"Waiting for 'Press any key' prompt (timeout: {timeout}s)...")

    if not HAS_WEBSOCKET:
        print("ERROR: websocket-client not installed. Install with: pip install websocket-client")
        sys.exit(1)

    # Create WebSocket connection with auth header
    ws = websocket.create_connection(
        ws_url,
        header=f"Authorization: Bearer {token}".encode(),
        sslopt={"cert_reqs": ssl.CERT_NONE},
        timeout=30
    )

    start = time.time()
    key_sent = False

    try:
        while time.time() - start < timeout:
            try:
                data = ws.recv()
                if isinstance(data, bytes):
                    text = data.decode("utf-8", errors="replace")
                else:
                    text = str(data)

                if "Press any key" in text or "Press any key" in text.upper():
                    print("Detected 'Press any key' prompt. Sending keypress...")
                    # Send space key (ASCII 32)
                    ws.send(b" ")
                    key_sent = True
                    print("Keypress sent successfully.")
                    time.sleep(2)
                    ws.close()
                    break

            except websocket.WebSocketTimeoutException:
                continue
            except websocket.WebSocketConnectionClosedException:
                print("Console connection closed by server. Retrying...")
                time.sleep(5)
                if time.time() - start >= timeout:
                    break
                ws = websocket.create_connection(
                    ws_url,
                    header=f"Authorization: Bearer {token}".encode(),
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    timeout=30
                )

    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    if not key_sent:
        print(f"Timeout reached ({timeout}s) without detecting 'Press any key' prompt.")
        print("The VM may have already booted or the prompt was missed.")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Inject keypress into KubeVirt VMI console")
    parser.add_argument("--vmi", required=True, help="VMI name")
    parser.add_argument("--namespace", required=True, help="Namespace")
    parser.add_argument("--kubeconfig", required=True, help="Path to kubeconfig")
    parser.add_argument("--timeout", type=int, default=180, help="Timeout in seconds (default: 180)")
    args = parser.parse_args()

    inject_key(args.kubeconfig, args.vmi, args.namespace, args.timeout)


if __name__ == "__main__":
    main()
