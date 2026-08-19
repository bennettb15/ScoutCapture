# ScoutCapture Web Contract

Phase 2C-06 adds the smallest executable web-facing contract aligned with the
canonical Supabase model.

## Files

- `openapi/scoutcapture-phase-2c-06.yaml`: OpenAPI contract for authenticated,
  org-scoped property reads.
- `mock/property_list_stub.py`: Runnable local stub for the contract.
- `mock/fixtures.json`: Minimal fixture data used by the stub.
- `test/test_properties_contract.sh`: Verifiable test call path.

## Run The Stub

```bash
python3 web-contract/mock/property_list_stub.py
```

Then call:

```bash
curl -sSf \
  -H "Authorization: Bearer owner-token" \
  -H "X-Scout-Org-Id: 10000000-0000-0000-0000-000000000001" \
  "http://127.0.0.1:8787/v1/properties?limit=10"
```

## Run The Verification Call

```bash
zsh web-contract/test/test_properties_contract.sh
```
