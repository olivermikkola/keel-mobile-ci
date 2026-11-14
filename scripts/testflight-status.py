#!/usr/bin/env python3
"""Inspect TestFlight; optionally unblock one explicitly selected internal build."""
import argparse
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt


def integration_value(name):
    value = os.environ[name]
    # Codemagic can supply CLI-compatible references instead of raw values.
    if value.startswith("@file:"):
        return Path(value[6:]).read_text().strip()
    if value.startswith("@env:"):
        return os.environ[value[5:]]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enable-internal-build", help="Exact Apple build UUID to declare exempt and add to the existing internal group")
    parser.add_argument("--rename-app", action="store_true", help="Rename the editable primary app listing to Keel Mobile - Local Coding")
    parser.add_argument("--wait-for-build-version", help="Wait up to ten minutes for this uploaded build number to enter internal testing")
    args = parser.parse_args()
    required = ("APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_KEY_IDENTIFIER",
                "APP_STORE_CONNECT_PRIVATE_KEY")
    if any(not os.environ.get(name) for name in required):
        raise SystemExit("Missing Apple integration credentials; no request was sent.")
    now = int(time.time())
    try:
        token = jwt.encode(
            {"iss": integration_value(required[0]), "iat": now, "exp": now + 900,
             "aud": "appstoreconnect-v1"},
            integration_value(required[2]), algorithm="ES256",
            headers={"kid": integration_value(required[1]), "typ": "JWT"},
        )
    except (ValueError, KeyError, OSError):
        raise SystemExit("Could not load the existing Apple integration credentials.") from None

    def request(method, path, data=None, **query):
        url = "https://api.appstoreconnect.apple.com/v1/" + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url, data=body, method=method,
                                     headers={"Authorization": "Bearer " + token,
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                payload = response.read()
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            # Never print request headers, JWTs, keys, or raw error responses.
            try:
                codes = [entry.get("code", "unknown") for entry in json.load(error).get("errors", [])]
            except (ValueError, OSError):
                codes = []
            raise SystemExit(f"Apple status request failed: HTTP {error.code} ({path}); codes={codes}.") from None

    def get(path, **query):
        return request("GET", path, **query)

    bundle = "com.olivermikkola.keelmobile"
    apps = get("apps", **{"filter[bundleId]": bundle})["data"]
    report = {"bundle_id": bundle, "apps": []}
    if (args.enable_internal_build or args.rename_app) and len(apps) != 1:
        raise SystemExit("Changes require exactly one matching Apple app.")
    for app in apps:
        app_id = app["id"]
        if app["attributes"]["bundleId"] != bundle:
            raise SystemExit("Apple returned a different bundle ID; stopping.")
        print(f"Found Apple app {app_id}: {app['attributes']['name']} ({app['attributes']['bundleId']})", flush=True)
        builds = get("builds", **{"filter[app]": app_id, "limit": 10, "sort": "-uploadedDate"})["data"]
        groups = get(f"apps/{app_id}/betaGroups", limit=100)["data"]
        if args.wait_for_build_version:
            for attempt in range(21):
                expected = next((build for build in builds if build["attributes"]["version"] == args.wait_for_build_version), None)
                state = "not yet listed"
                if expected:
                    state = get(f"builds/{expected['id']}/buildBetaDetail")["data"]["attributes"]["internalBuildState"]
                print(f"Apple build {args.wait_for_build_version}: {state}", flush=True)
                if state == "IN_BETA_TESTING" or attempt == 20:
                    break
                time.sleep(30)
                builds = get("builds", **{"filter[app]": app_id, "limit": 10, "sort": "-uploadedDate"})["data"]
        if args.enable_internal_build:
            selected = next((build for build in builds if build["id"] == args.enable_internal_build), None)
            if not selected or selected["attributes"].get("processingState") != "VALID" or selected["attributes"].get("expired"):
                raise SystemExit("Selected build is not an unexpired, valid build belonging to Keel Mobile.")
            if selected["attributes"].get("usesNonExemptEncryption") is True:
                raise SystemExit("Selected build already declares non-exempt encryption; stopping.")
            internal = [group for group in groups if group["attributes"].get("isInternalGroup")
                        and group["attributes"]["name"] == "Keel Mobile - Pre Alpha"]
            if len(internal) != 1:
                raise SystemExit("Expected the existing Keel Mobile - Pre Alpha internal group.")
            # This app uses Apple HTTPS/Keychain and SHA-256 only. Match the
            # ITSAppUsesNonExemptEncryption=false setting already in project.yml.
            if selected["attributes"].get("usesNonExemptEncryption") is None:
                request("PATCH", f"builds/{selected['id']}", {"data": {
                    "type": "builds", "id": selected["id"],
                    "attributes": {"usesNonExemptEncryption": False}}})
            group_id = internal[0]["id"]
            assigned = get(f"betaGroups/{group_id}/builds", limit=100)["data"]
            # Automatic internal groups reject manual build assignments. Apple
            # adds eligible builds after export compliance has cleared.
            if (selected["id"] not in {build["id"] for build in assigned}
                    and not internal[0]["attributes"].get("hasAccessToAllBuilds")):
                request("POST", f"betaGroups/{group_id}/relationships/builds", {
                    "data": [{"type": "builds", "id": selected["id"]}]})
            print("Updated selected build's export declaration; checking existing internal-group eligibility.", flush=True)
            builds = get("builds", **{"filter[app]": app_id, "limit": 10, "sort": "-uploadedDate"})["data"]
        if args.rename_app:
            infos = get(f"apps/{app_id}/appInfos")["data"]
            editable = [info for info in infos if info["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"]
            if len(editable) != 1:
                raise SystemExit("Expected one editable app-info record before renaming.")
            locales = get(f"appInfos/{editable[0]['id']}/appInfoLocalizations")["data"]
            english = [locale for locale in locales if locale["attributes"]["locale"] == app["attributes"]["primaryLocale"]]
            listing_name = "Keel Mobile - Local Coding"
            if len(english) != 1 or english[0]["attributes"]["name"] not in ("WebGPU Agent", "Keel Mobile", listing_name):
                raise SystemExit("Unexpected app listing name; stopping before renaming.")
            locale_id = english[0]["id"]
            request("PATCH", f"appInfoLocalizations/{locale_id}", {"data": {
                "type": "appInfoLocalizations", "id": locale_id,
                "attributes": {"name": listing_name}}})
            app = get(f"apps/{app_id}")["data"]
        entry = {"id": app_id, "name": app["attributes"]["name"],
                 "testflight_url": f"https://appstoreconnect.apple.com/apps/{app_id}/testflight/ios",
                 "builds": [], "groups": []}
        for build in builds:
            attributes = build["attributes"]
            detail = get(f"builds/{build['id']}/buildBetaDetail")["data"]["attributes"]
            entry["builds"].append({"id": build["id"], **{
                key: attributes.get(key) for key in
                ("version", "processingState", "expired", "usesNonExemptEncryption", "uploadedDate")
            }, "beta_detail": detail})
        for group in groups:
            attributes = group["attributes"]
            assigned = get(f"betaGroups/{group['id']}/builds", limit=100)["data"]
            testers = get(f"betaGroups/{group['id']}/betaTesters", limit=200)["data"]
            entry["groups"].append({"id": group["id"], **{
                key: attributes.get(key) for key in ("name", "isInternalGroup", "hasAccessToAllBuilds")
            }, "build_ids": [build["id"] for build in assigned], "tester_count": len(testers),
                "tester_states": [tester["attributes"].get("state") for tester in testers]})
        report["apps"].append(entry)
    Path("artifacts").mkdir(exist_ok=True)
    Path("artifacts/testflight-status.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if not apps:
        raise SystemExit("This Apple integration cannot see an app record for Keel Mobile.")
    if args.enable_internal_build:
        selected = next(build for build in report["apps"][0]["builds"] if build["id"] == args.enable_internal_build)
        if selected["beta_detail"].get("internalBuildState") != "IN_BETA_TESTING":
            raise SystemExit("Apple has not yet marked the selected build IN_BETA_TESTING; recheck status.")
    if args.wait_for_build_version:
        for entry in report["apps"]:
            for build in entry["builds"]:
                if (build["version"] == args.wait_for_build_version
                        and build["beta_detail"].get("internalBuildState") == "IN_BETA_TESTING"
                        and any(group["isInternalGroup"] and group["tester_count"] > 0
                                and build["id"] in group["build_ids"] for group in entry["groups"])):
                    return
        raise SystemExit("Requested build is not yet available to an internal group with testers.")


if __name__ == "__main__":
    main()
