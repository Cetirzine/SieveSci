#!/usr/bin/env python3
"""Regenerates Resources/catalog/chemcrow-chem-weapons-inchikeys.json.

For every entry of ChemCrow's controlled-chemical list (chemcrow-chem-weapons.csv) it asks PubChem
for the structure's InChIKey, so `chem_lookup` can screen by structure instead of by how a SMILES
string happens to be written. Standard library only; PubChem allows about 5 requests per second.

    python3 scripts/gen-controlled-inchikeys.py
"""
import csv, json, os, sys, time, urllib.error, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Sources/SieveSciCore/Resources/catalog")
SRC = os.path.join(CATALOG, "chemcrow-chem-weapons.csv")
OUT = os.path.join(CATALOG, "chemcrow-chem-weapons-inchikeys.json")
PUG = "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/smiles/property/InChIKey/JSON"


def inchikey(smiles):
    body = urllib.parse.urlencode({"smiles": smiles}).encode()
    for attempt in range(4):
        try:
            req = urllib.request.Request(PUG, data=body, headers={"User-Agent": "SieveSci catalog generator"})
            with urllib.request.urlopen(req, timeout=30) as r:
                p = json.load(r)["PropertyTable"]["Properties"][0]
                return p.get("CID"), p.get("InChIKey")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None, None
            time.sleep(2 ** attempt)
        except (urllib.error.URLError, TimeoutError, KeyError, IndexError):
            time.sleep(2 ** attempt)
    return None, None


def main():
    entries, missing = [], []
    with open(SRC, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            cas = row["cas"].strip("() ")
            cid, key = inchikey(row["smiles"])
            if not key:
                missing.append(cas)
            entries.append({"cas": cas, "source": row["source"], "smiles": row["smiles"], "cid": cid, "inchikey": key})
            time.sleep(0.25)
    out = {"generated": time.strftime("%Y-%m-%d"), "source": "PubChem PUG REST, from chemcrow-chem-weapons.csv",
           "entries": entries}
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"{len(entries)} entries, {len(entries) - len(missing)} with InChIKey; unresolved: {missing}")


if __name__ == "__main__":
    sys.exit(main())
