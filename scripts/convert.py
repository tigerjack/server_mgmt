import sys, yaml

data = yaml.safe_load(open(sys.argv[1]))
entries = []
for name, u in data["users"].items():
    entries.append({
        "username": name,
        "displayname": u.get("displayname", name),
        "email": u.get("email", ""),
        "password_hash": u["password"],
        "groups": u.get("groups", ["users"]),
        **({"disabled": True} if u.get("disabled") else {}),
    })
print(yaml.dump({"authelia_users": entries},
                sort_keys=False, default_flow_style=False, width=1000))
