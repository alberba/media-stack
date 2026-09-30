"""The quality profile the Template brings to each Radarr/Sonarr, synced by Recyclarr.

The Operator picks which qualities to accept (QUALITIES in .env, chosen in
scripts/setup.sh); the TRaSH Guides custom formats then score the releases within them.
The profile has the Template's own name, so profiles the Operator made are never
touched. Its qualities, their order and the cutoff are only written when the profile
is created: after that they are the Operator's, and each run only refreshes the
custom formats and their scores.
"""

import hashlib
import json
import os

from .steps import PROFILE

# Every quality the wizard offers, best first. Each maps to its name, or its group of
# names, in Radarr and in Sonarr (None: that manager has no such quality).
QUALITIES = [
    ("Remux-2160p", "Remux-2160p", "Bluray-2160p Remux"),
    ("Bluray-2160p", "Bluray-2160p", "Bluray-2160p"),
    ("WEB 2160p", ["WEBDL-2160p", "WEBRip-2160p"], ["WEBDL-2160p", "WEBRip-2160p"]),
    ("HDTV-2160p", "HDTV-2160p", "HDTV-2160p"),
    ("Remux-1080p", "Remux-1080p", "Bluray-1080p Remux"),
    ("Bluray-1080p", "Bluray-1080p", "Bluray-1080p"),
    ("WEB 1080p", ["WEBDL-1080p", "WEBRip-1080p"], ["WEBDL-1080p", "WEBRip-1080p"]),
    ("HDTV-1080p", "HDTV-1080p", "HDTV-1080p"),
    ("Bluray-720p", "Bluray-720p", "Bluray-720p"),
    ("WEB 720p", ["WEBDL-720p", "WEBRip-720p"], ["WEBDL-720p", "WEBRip-720p"]),
    ("HDTV-720p", "HDTV-720p", "HDTV-720p"),
    ("Bluray-576p", "Bluray-576p", "Bluray-576p"),
    ("Bluray-480p", "Bluray-480p", "Bluray-480p"),
    ("WEB 480p", ["WEBDL-480p", "WEBRip-480p"], ["WEBDL-480p", "WEBRip-480p"]),
    ("DVD", "DVD", "DVD"),
    ("SDTV", "SDTV", "SDTV"),
    ("Raw-HD", "Raw-HD", "Raw-HD"),
    ("BR-DISK", "BR-DISK", None),
]
NAMES = [q[0] for q in QUALITIES]

# TRaSH Guides custom formats (trash_id, from docs/json/<service>/cf/*.json), scored as
# the guide says. UNWANTED and TIERS go to every profile; the language ones depend on
# whether the manager is the VO one.
TRASH = {
    "radarr": {
        "unwanted": ["ed38b889b31be83fda192888e2286d83", "90a6f9a284dff5103f6346090e6280c8",
                     "e204b80c87be9497a8a6eaff48f72905", "b8cd450cbfa689c0259a01d9e29ba3d6",
                     "0a3f082873eb454bde444150b70253cc", "dc98083864ea246d05a42df0d05f81cc",
                     "bfd8eb01832d646a0a89c4deb46f8564"],
        "tiers": ["ed27ebfef2f323e964fb1f61391bcb35", "c20c8647f2746a1f4c4262b0fbbeeeae",
                  "5608c71bcebba0a5e666223bae8c9227", "4d74ac4c4db0b64bff6ce0cffef99bf0",
                  "a58f517a70193f8e578056642178419d", "e71939fae578037e7aed3ee219bbe7c1",
                  "c20f169ef63c5f40c2def54abaf4438e", "403816d65392c79236dcb6dd591aeda4",
                  "af94e0fe497124d1f9ce732069ec8c3b", "e7718d7a3ce595f289bfee26adc178f5",
                  "ae43b294509409a6a13919dedd4764c4", "5caaaa1c08c1742aa4342d8c4cc463f2"],
        # Language: Not Original, Bad Dual Groups
        "vo": ["d6e9318c875905d6cfb5bee961afcea9", "b6832f586342ef70d9c128d40c07b872"],
    },
    "sonarr": {
        "unwanted": ["85c61753df5da1fb2aab6f2a47426b09", "9c11cd3f07101cdba90a2d81cf0e56b4",
                     "e2315f990da2e2cbfc9fa5b7a6fcfe48", "fbcb31d8dabd2a319072b84fc0b7249c",
                     "47435ece6b99a0b477caf360e79ba0bb", "23297a736ca77c0fc8e70f8edd7ee56c"],
        "tiers": ["d6819cba26b1a6508138d25fb5e32293", "c2216b7b8aa545dc1ce8388c618f8d57",
                  "e6258996055b9fbab7e9cb2f75819294", "58790d4e2fdcd9733aa7ae68ba2bb503",
                  "d84935abd3f8556dcd51d4f27e22d0a6", "ec8fa7296b64e8cd390a1600981f3923",
                  "eb3d5cc0a2be0db205fb823640db6a3c", "44e7c4de10ae50265753082e5dc76047"],
        "vo": ["ae575f95ab639ba5d15f663bf019e3e8", "32b367365729d530ca1c124a0b180c64"],
    },
}

# TRaSH has no Spanish formats, so the Template brings its own: in the Core managers a
# release with Spanish audio (alone, or DUAL/MULTi) beats the best release tier.
SPANISH_SCORE = 2000
SPANISH_LANGUAGE_ID = 3  # Language.Spanish in Radarr and Sonarr


def spanish_trash_id(kind):
    return hashlib.md5(f"media-stack-spanish-{kind}".encode()).hexdigest()


def spanish_format(kind):
    return {
        "trash_id": spanish_trash_id(kind),
        "trash_scores": {"default": SPANISH_SCORE},
        "name": "Spanish",
        "includeCustomFormatWhenRenaming": False,
        "specifications": [{
            "name": "Spanish", "implementation": "LanguageSpecification",
            "negate": False, "required": True,
            "fields": {"value": SPANISH_LANGUAGE_ID, "exceptLanguage": False},
        }],
    }


def profile_qualities(kind, selected):
    column = 1 if kind == "radarr" else 2
    out = []
    for q in QUALITIES:
        target = q[column]
        if target is None:
            continue
        entry = {"name": q[0] if isinstance(target, list) else target, "enabled": q[0] in selected}
        if isinstance(target, list):
            entry["qualities"] = target
        out.append(entry)
    return out


def instance(m, selected, create):
    """Recyclarr's config for one manager. `create`: the profile does not exist yet."""
    profile = {"name": PROFILE}
    if create:
        qualities = profile_qualities(m.kind, selected)
        top = next((q["name"] for q in qualities if q["enabled"]), None)
        if top is None:
            return None
        profile.update({"qualities": qualities, "quality_sort": "top",
                        "upgrade": {"allowed": True, "until_quality": top, "until_score": 10000}})
    ids = TRASH[m.kind]
    languages = ids["vo"] if m.vo else [spanish_trash_id(m.kind)]
    return {
        "base_url": f"http://{m.key}:{m.port}",
        "api_key": m.api_key,
        "quality_profiles": [profile],
        "custom_formats": [{"trash_ids": ids["unwanted"] + ids["tiers"] + languages,
                            "assign_scores_to": [{"name": PROFILE}]}],
    }


def write_config(folder, managers, selected, existing_profiles):
    """Writes recyclarr.yml, settings.yml and the Template's own custom formats.
    existing_profiles: manager key -> names of its quality profiles. JSON is valid YAML.
    Returns the lines to log."""
    config = {"radarr": {}, "sonarr": {}}
    log = []
    for m in managers:
        settings = instance(m, selected, PROFILE not in existing_profiles[m.key])
        if settings is None:
            log.append(f"quality: WARN none of QUALITIES exists in {m.name} ({', '.join(selected)}), its profile skipped")
            continue
        config[m.kind][m.key.replace("-", "_")] = settings
    providers = []
    for kind in ("radarr", "sonarr"):
        path = os.path.join(folder, "custom-formats", kind)
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "spanish.json"), "w", encoding="utf-8") as f:
            json.dump(spanish_format(kind), f, indent=2)
        providers.append({"name": f"media-stack-{kind}", "type": "custom-formats", "service": kind, "path": path})
    # It holds the managers' API keys.
    fd = os.open(os.path.join(folder, "recyclarr.yml"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with open(fd, "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in config.items() if v}, f, indent=2)
    with open(os.path.join(folder, "settings.yml"), "w", encoding="utf-8") as f:
        json.dump({"resource_providers": providers}, f, indent=2)
    return log
