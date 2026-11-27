#!/usr/bin/env python3
"""Собирает лицензии и уведомления сторонних компонентов, которые входят в сборку Mono VPN.

Вход — вывод `go list -deps -json` для `./cgo_bridge` libXray с GOOS=ios (его делает
`generate-third-party-notices.sh`): учитываются только пакеты, которые реально компилируются
в libXray.a для iOS. Для каждого модуля берутся файлы лицензий, NOTICE, PATENTS и AUTHORS
из корня модуля и из каталогов пакетов, которые входят в сборку (вложенные лицензии
заимствованного кода). Добавляется стандартная библиотека и рантайм Go из GOROOT.

Выход:
  MonoVPN/Resources/ThirdPartyNotices.json — данные для экрана «Лицензии» в приложении;
  THIRD_PARTY_NOTICES.md                   — то же для репозитория.

Запуск: python3 -I third_party_notices.py <go-list.json> <GOROOT> <libxray-version> <go-version> <repo-root>
"""
import json
import os
import re
import subprocess
import sys

NOTICE_PATTERN = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|PATENTS|AUTHORS)([.-].*)?$", re.IGNORECASE)

# Репозитории модулей, путь которых не совпадает с адресом исходников.
SOURCE_OVERRIDES = {
    "golang.org/x/": "https://go.googlesource.com/",
    "google.golang.org/grpc": "https://github.com/grpc/grpc-go",
    "google.golang.org/protobuf": "https://go.googlesource.com/protobuf",
    "google.golang.org/genproto": "https://github.com/googleapis/go-genproto",
    "gopkg.in/yaml.v2": "https://github.com/go-yaml/yaml",
    "go4.org/netipx": "https://github.com/go4org/netipx",
    "golang.zx2c4.com/wireguard": "https://git.zx2c4.com/wireguard-go",
    "layeh.com/gopher-luar": "https://github.com/layeh/gopher-luar",
    "lukechampine.com/blake3": "https://github.com/lukechampine/blake3",
}


def read_json_stream(path):
    """`go list -json` печатает объекты подряд, без массива."""
    text = open(path, encoding="utf-8").read()
    decoder = json.JSONDecoder()
    index, objects = 0, []
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        obj, index = decoder.raw_decode(text, index)
        objects.append(obj)
    return objects


def classify(text):
    """Тип лицензии по тексту (SPDX). В одном файле может быть несколько лицензий
    (например, MIT для модуля и Apache-2.0 для заимствованных файлов) — тогда `A AND B`.
    Неизвестный текст — `see text`."""
    compact = " ".join(text.split())
    if "Mozilla Public License Version 2.0" in compact or "Mozilla Public License, version 2.0" in compact:
        return "MPL-2.0"
    if "GNU LESSER GENERAL PUBLIC LICENSE" in compact and "Version 3" in compact:
        lower = compact.lower()
        return "LGPL-3.0 with static linking exception" if "static" in lower and "exception" in lower else "LGPL-3.0"
    found = []
    if "Permission is hereby granted, free of charge" in compact:
        found.append("MIT")
    if "Permission to use, copy, modify, and/or distribute" in compact:
        found.append("ISC")
    if "Redistribution and use in source and binary forms" in compact:
        found.append("BSD-3-Clause" if "Neither the name" in compact or "names of its contributors" in compact else "BSD-2-Clause")
    if "Apache License" in compact and "Version 2.0" in compact:
        found.append("Apache-2.0")
    return " AND ".join(found) if found else "see text"


def source_url(module):
    for prefix, base in SOURCE_OVERRIDES.items():
        if module.startswith(prefix):
            return base + module[len(prefix):].split("/")[0] if prefix.endswith("/") else base
    parts = module.split("/")
    return "https://" + "/".join(parts[:3])


def escape_module(path):
    """Экранирование пути модуля для proxy.golang.org (заглавные буквы → `!` + строчная)."""
    return re.sub(r"[A-Z]", lambda m: "!" + m.group(0).lower(), path)


def notice_files(directory):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    return [os.path.join(directory, n) for n in names
            if NOTICE_PATTERN.match(n) and os.path.isfile(os.path.join(directory, n))]


def file_headers(directory, names):
    """SPDX-заголовки компилируемых файлов пакета: (имя файла, лицензия, строки копирайта)."""
    result = []
    for name in sorted(names):
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as source:
            head = "".join(source.readline() for _ in range(12))
        ids = re.findall(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+)", head)
        holders = re.findall(r"(?:SPDX-FileCopyrightText:|Copyright)\s*(?:\(C\)|©)?\s*([^\n*]+?)\s*(?:\*/)?$", head, re.MULTILINE)
        for spdx in ids:
            result.append((name, spdx, [h.strip() for h in holders]))
    return result


# Копия исходников в репозитории Mono VPN (third_party/sources, mirror-third-party-sources.sh).
MIRROR_REPOSITORY = "https://github.com/irklch/MonoVPN"


def mirror_links(repo_root, libxray_version):
    """Ссылки на архивы в third_party/sources по SHA последнего коммита, который их менял:
    такой адрес не меняется при дальнейших коммитах. Пусто, если архивов нет или они не закоммичены."""
    directory = os.path.join(repo_root, "third_party", "sources")
    if not os.path.isdir(directory):
        return {}
    commit = subprocess.run(["git", "-C", repo_root, "log", "-1", "--format=%H", "--", "third_party/sources"],
                            capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", repo_root, "status", "--porcelain", "--", "third_party/sources"],
                           capture_output=True, text=True).stdout.strip()
    if not commit or dirty:
        raise SystemExit("error: commit third_party/sources before generating notices (links use its commit)")
    links = {}
    for name in sorted(os.listdir(directory)):
        url = f"{MIRROR_REPOSITORY}/raw/{commit}/third_party/sources/{name}"
        if name.endswith(".zip") and "@" in name:
            module, version = name[:-len(".zip")].split("@", 1)
            links[(module.replace("_", "/"), version)] = url
        elif name == f"libXray-{libxray_version}.tar.gz":
            links[("github.com/xtls/libxray", libxray_version)] = url
    return links


LGPL_NOTICE = (
    "Mono VPN использует эту библиотеку (статически, в составе libXray). Библиотека и её использование "
    "регулируются GNU Lesser General Public License v3 со специальным исключением для статической "
    "и динамической линковки (текст ниже); к ней приложены тексты GNU LGPL v3 и GNU GPL v3."
)


def main():
    go_list, goroot, libxray_version, go_version, repo_root = sys.argv[1:6]
    packages = [p for p in read_json_stream(go_list) if not p.get("Standard")]

    modules = {}
    for package in packages:
        module = package.get("Module") or {}
        path = module.get("Path")
        if not path:
            continue
        entry = modules.setdefault(path, {
            "path": path,
            "version": module.get("Version") or libxray_version,
            "dir": module.get("Dir"),
            "packageDirs": set(),
            "files": {},
        })
        entry["packageDirs"].add(package["Dir"])
        compiled = package.get("GoFiles", []) + package.get("CgoFiles", [])
        entry["files"].setdefault(package["Dir"], set()).update(compiled)

    mirrors = mirror_links(repo_root, libxray_version)
    components = []
    for path, module in modules.items():
        root = module["dir"]
        files = notice_files(root)
        # Вложенные лицензии: каталоги пакетов сборки и их родители внутри модуля.
        nested = set()
        for directory in module["packageDirs"]:
            current = directory
            while current.startswith(root) and current != root:
                nested.update(notice_files(current))
                current = os.path.dirname(current)
        texts = []
        for file in files + sorted(nested):
            relative = os.path.relpath(file, root)
            texts.append({"title": relative, "text": open(file, encoding="utf-8", errors="replace").read().strip()})
        license_texts = [t for t in texts if re.match(r"(?i)^(LICEN[CS]E|COPYING)", os.path.basename(t["title"]))]
        if not license_texts:
            raise SystemExit(f"error: no license file for {path}")
        kinds = []
        for text in license_texts:
            kind = classify(text["text"])
            label = kind if "/" not in text["title"] else f"{kind} ({os.path.dirname(text['title'])})"
            if label not in kinds:
                kinds.append(label)
        # Файлы с собственной лицензией, отличной от лицензии модуля (по SPDX-заголовку).
        # Сгруппированы по лицензии и правообладателю; указывается, если лицензия отличается
        # от лицензии модуля или правообладателя нет в текстах лицензий модуля.
        groups = {}
        module_ids = " ".join(kinds)
        module_text = " ".join(" ".join(t["text"].split()) for t in texts)
        for directory, names in sorted(module["files"].items()):
            for name, spdx, holders in file_headers(directory, names):
                # Правообладатель без года: «2017-2025 WireGuard LLC» → «WireGuard LLC».
                owners = [re.sub(r"^[0-9\s,-]+", "", h).split(". All rights")[0].split(". All Rights")[0].strip() for h in holders]
                if spdx in module_ids and all(owner in module_text for owner in owners):
                    continue
                key = (spdx, "; ".join(h.rstrip(".") for h in holders))
                groups.setdefault(key, []).append(os.path.relpath(os.path.join(directory, name), root))
        notes = []
        for (spdx, holder), files in sorted(groups.items()):
            shown = ", ".join(sorted(files)[:3]) + (f" and {len(files) - 3} more" if len(files) > 3 else "")
            notes.append(f"{spdx}" + (f", Copyright {holder}" if holder else "") + f" — {len(files)} file(s): {shown}")
        # LGPL-3.0 §4(b): к программе прилагается текст GNU GPL v3, на который ссылается LGPL.
        if any(k.startswith("LGPL") for k in kinds):
            gpl = os.path.join(os.path.dirname(os.path.abspath(__file__)), "licenses", "GPL-3.0.txt")
            texts.append({"title": "GNU General Public License v3 (referenced by LGPL-3.0)",
                          "text": open(gpl, encoding="utf-8").read().strip()})
        version = module["version"]
        repository = source_url(path)
        if path == "github.com/xtls/libxray":
            source = f"https://github.com/XTLS/libXray/tree/{version}"
            archive = f"https://github.com/XTLS/libXray/archive/refs/tags/{version}.tar.gz"
        else:
            source = repository
            archive = f"https://proxy.golang.org/{escape_module(path)}/@v/{escape_module(version)}.zip"
        if any(k.startswith("LGPL") for k in kinds):
            notes.insert(0, LGPL_NOTICE)
        components.append({
            "name": path,
            "version": version,
            "license": ", ".join(kinds),
            "source": source,
            "sourceArchive": archive,
            "mirror": mirrors.get((path, version)),
            "notes": notes,
            "texts": texts,
        })

    # Go: стандартная библиотека и рантайм статически входят в libXray.
    go_texts = [{"title": os.path.basename(f), "text": open(f, encoding="utf-8").read().strip()}
                for f in notice_files(goroot)]
    components.append({
        "name": "Go (standard library and runtime)",
        "version": go_version,
        "license": classify(go_texts[0]["text"]),
        "source": "https://go.googlesource.com/go",
        "sourceArchive": f"https://go.dev/dl/{go_version}.src.tar.gz",
        "mirror": None,
        "notes": [],
        "texts": go_texts,
    })

    priority = {"github.com/xtls/xray-core": 0, "github.com/xtls/libxray": 1}
    components.sort(key=lambda c: (priority.get(c["name"], 2), c["name"].lower()))

    # Xray-core: тег, а не псевдоверсия, — так его проще найти пользователю.
    for component in components:
        if component["name"] == "github.com/xtls/xray-core":
            component["source"] = "https://github.com/XTLS/Xray-core/tree/v26.11.9"
            component["displayVersion"] = f"v26.11.9 ({component['version']})"

    document = {"libXray": libxray_version, "go": go_version, "components": components}
    resources = os.path.join(repo_root, "MonoVPN", "Resources", "ThirdPartyNotices.json")
    with open(resources, "w", encoding="utf-8") as out:
        json.dump(document, out, ensure_ascii=False, indent=1)
        out.write("\n")

    lines = [
        "# Third-party notices",
        "",
        "Mono VPN includes the following third-party software, statically linked into the Packet Tunnel",
        f"extension as part of libXray {libxray_version} (Xray-core v26.11.9), built with {go_version}.",
        "The list is generated by `MonoVPN/Scripts/generate-third-party-notices.sh` from the packages",
        "that are actually compiled for iOS. The same texts are available in the app: Subscription → Licenses.",
        "",
        "Source code of every component, in the exact version used, is available at the links below",
        "(`Source archive` is the module archive from the Go module proxy or the release tag archive).",
        "For components under MPL-2.0 and for libXray, a copy of the exact source archive is also kept in",
        "this repository: [third_party/sources](third_party/sources/README.md) (`Mirror`).",
        "Mono VPN does not modify any of these components.",
        "",
        "| Component | Version | License |",
        "|---|---|---|",
    ]
    for c in components:
        lines.append(f"| {c['name']} | {c.get('displayVersion', c['version'])} | {c['license']} |")
    for c in components:
        lines += ["", "---", "", f"## {c['name']} {c.get('displayVersion', c['version'])}", "",
                  f"License: {c['license']}  ", f"Source: {c['source']}  ", f"Source archive: {c['sourceArchive']}"
                  + (f"  \nMirror: {c['mirror']}" if c.get("mirror") else "")]
        if c["notes"]:
            lines += ["", "Files under a different license (SPDX headers; the full license texts are listed in this document):", ""]
            lines += [f"- {note}" for note in c["notes"]]
        for text in c["texts"]:
            lines += ["", f"### {text['title']}", "", "```text", text["text"], "```"]
    with open(os.path.join(repo_root, "THIRD_PARTY_NOTICES.md"), "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")

    for c in components:
        print(f"{c['license']:45} {c['name']} {c.get('displayVersion', c['version'])} ({len(c['texts'])} files)")
        for note in c["notes"]:
            print(f"{'':45}   note: {note}")


if __name__ == "__main__":
    main()
