#!/usr/bin/env python3
"""Hands the released phone build to TestFlight's public group and sends it to beta review.

Runs after every successful release on main, so a release that failed after the upload is picked up
by the next push. Each step checks App Store Connect first, so running again never submits twice.
Signs in with the App Store Connect key in APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER_ID.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = 'com.pdparchitect.noodle.mobile'
GROUP = 'External'
LIMIT = 4000  # App Store Connect's cap on What to Test.
PATIENCE = 45 * 60
REVIEWED = {'WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW', 'BETA_APPROVED', 'IN_BETA_TESTING', 'READY_FOR_TESTING'}
REFUSED = {
    'MISSING_EXPORT_COMPLIANCE': 'The build is missing export compliance; answer it in App Store Connect.',
    'BETA_REJECTED': 'Beta review rejected the build; see App Store Connect.',
    'EXPIRED': 'The build expired before it reached testers.',
}


def what_to_test(notes):
    # A "What to Test" heading, when a version has one, is all testers see; otherwise the whole section.
    section = re.search(r'^### What to Test\s*$(.*?)(?=^### |\Z)', notes, re.M | re.S | re.I)
    text = section[1] if section else notes
    text = re.sub(r'^#+[ \t]*(.*?)[ \t]*$', r'\1', text, flags=re.M)
    text = re.sub(r'^[-*] ', '• ', text, flags=re.M)
    text = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'\*\*(.+?)\*\*|`([^`]+)`', lambda m: m[1] or m[2], text)
    text = re.sub(r'\n{3,}', '\n\n', text).strip()
    if len(text) > LIMIT:
        text = text[:text.rfind('\n', 0, LIMIT - 1) + 1] + '…'
    return text


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def raw_signature(der):
    # openssl writes ECDSA signatures as DER; JWT wants r and s as two 32-byte numbers.
    def integer(offset):
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length]
        return value.lstrip(b'\0').rjust(32, b'\0'), offset + 2 + length
    r, offset = integer(2 if der[1] < 0x80 else 3)
    s, _ = integer(offset)
    return r + s


def token(key_path, key_id, issuer, now=None):
    now = int(time.time()) if now is None else now
    header = base64url(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    payload = base64url(json.dumps({'iss': issuer, 'iat': now, 'exp': now + 1200,
                                    'aud': 'appstoreconnect-v1'}).encode())
    signing = f'{header}.{payload}'
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key_path)], input=signing.encode(),
                         check=True, capture_output=True).stdout
    return f'{signing}.{base64url(raw_signature(der))}'


class Connect:
    def __init__(self, key_path, key_id, issuer):
        self.key = (key_path, key_id, issuer)
        self.issued = 0

    def __call__(self, method, path, body=None):
        # Tokens last 20 minutes and waiting for processing can take longer.
        if time.time() - self.issued > 600:
            self.bearer, self.issued = token(*self.key), time.time()
        for attempt in range(4):
            request = urllib.request.Request(
                'https://api.appstoreconnect.apple.com' + path, method=method,
                data=json.dumps(body).encode() if body is not None else None,
                headers={'Authorization': f'Bearer {self.bearer}', 'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = response.read()
                    return json.loads(data) if data else {}
            except urllib.error.HTTPError as error:
                if (error.code == 429 or error.code >= 500) and attempt < 3:
                    time.sleep(10 * (attempt + 1))
                    continue
                raise RuntimeError(f'{method} {path} failed with {error.code}: {error.read().decode()[:800]}')


def hand_over(connect, version, notes, released, wait, sleep=time.sleep, clock=time.monotonic):
    if not released:
        print(f'Mobile {version} is not released yet; nothing to hand to TestFlight.')
        return
    query = lambda fields: urllib.parse.urlencode(fields, safe='[]')
    apps = connect('GET', '/v1/apps?' + query({'filter[bundleId]': BUNDLE_ID}))['data']
    app = next(a['id'] for a in apps if a['attributes']['bundleId'] == BUNDLE_ID)

    deadline = clock() + PATIENCE
    while True:
        builds = connect('GET', '/v1/builds?' + query({
            'filter[app]': app, 'filter[preReleaseVersion.version]': version,
            'sort': '-uploadedDate', 'limit': 1}))['data']
        if not builds and not wait:
            print(f'App Store Connect has no build of Mobile {version}; nothing to hand to TestFlight.')
            return
        if builds:
            build = builds[0]['id']
            processing = builds[0]['attributes']['processingState']
            if processing in ('FAILED', 'INVALID'):
                raise RuntimeError(f'Apple processing failed for Mobile {version}: {processing}')
            if processing == 'VALID':
                state = connect('GET', f'/v1/builds/{build}/buildBetaDetail')['data']['attributes']['externalBuildState']
                if state != 'PROCESSING':
                    break
        if clock() > deadline:
            raise RuntimeError(f'Mobile {version} did not appear ready in App Store Connect in time')
        print(f'Waiting for Apple to process Mobile {version}…')
        sleep(60)

    if state in REFUSED:
        raise RuntimeError(REFUSED[state])
    if state not in REVIEWED and state != 'READY_FOR_BETA_SUBMISSION':
        raise RuntimeError(f'Unexpected TestFlight state for Mobile {version}: {state}')

    whats_new = what_to_test(notes)
    localizations = connect('GET', f'/v1/builds/{build}/betaBuildLocalizations')['data']
    for localization in localizations:
        connect('PATCH', f'/v1/betaBuildLocalizations/{localization["id"]}', {'data': {
            'type': 'betaBuildLocalizations', 'id': localization['id'], 'attributes': {'whatsNew': whats_new}}})
    if not localizations:
        connect('POST', '/v1/betaBuildLocalizations', {'data': {
            'type': 'betaBuildLocalizations', 'attributes': {'locale': 'en-US', 'whatsNew': whats_new},
            'relationships': {'build': {'data': {'type': 'builds', 'id': build}}}}})

    groups = connect('GET', '/v1/betaGroups?' + query({'filter[app]': app, 'filter[name]': GROUP}))['data']
    group = next((g['id'] for g in groups
                  if g['attributes']['name'] == GROUP and not g['attributes']['isInternalGroup']), None)
    if not group:
        raise RuntimeError(f'App Store Connect has no external TestFlight group named {GROUP}')
    connect('POST', f'/v1/betaGroups/{group}/relationships/builds', {'data': [{'type': 'builds', 'id': build}]})

    if state == 'READY_FOR_BETA_SUBMISSION':
        connect('POST', '/v1/betaAppReviewSubmissions', {'data': {
            'type': 'betaAppReviewSubmissions',
            'relationships': {'build': {'data': {'type': 'builds', 'id': build}}}}})
        print(f'Mobile {version} is in {GROUP} and waiting for beta review.')
    else:
        print(f'Mobile {version} is in {GROUP}; beta review already has it ({state}).')


def release_state(root, tag):
    # Tagged on the checked-out commit means this release just uploaded the build, so it is worth
    # waiting for; an older tag's build is either in App Store Connect already or never made it.
    tagged = subprocess.check_output(['git', '-C', str(root), 'tag', '--list', tag], text=True).strip()
    here = subprocess.check_output(['git', '-C', str(root), 'tag', '--points-at', 'HEAD'], text=True).split()
    return bool(tagged), tag in here


def main():
    spec = importlib.util.spec_from_file_location('versions', ROOT / 'scripts/release-versions.py')
    versions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(versions)
    version, tag = versions.version('mobile')
    released, uploaded = release_state(ROOT, tag)
    connect = Connect(os.environ['APPLE_API_KEY_PATH'], os.environ['APPLE_API_KEY_ID'],
                      os.environ['APPLE_API_ISSUER_ID'])
    hand_over(connect, version, versions.notes('mobile') if released else '', released, uploaded)


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as error:
        sys.exit(str(error))
