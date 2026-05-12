#!/usr/bin/env python3
"""
Vérification côté client LAN qu'AdGuard Home est actif sur le routeur OpenWrt.
Compatible Linux et Windows. Requiert Python 3.6+, aucune dépendance externe.

Usage :
  python3 test-adguardhome-client.py [IP_ROUTEUR]
  python  test-adguardhome-client.py [IP_ROUTEUR]   (Windows)
"""

import sys
import os
import socket
import subprocess
import platform
import struct
import random

# ─── Vérification des dépendances ─────────────────────────────────────────────
def check_deps():
    errors = []

    # Python 3.6+ requis (f-strings, subprocess.run)
    if sys.version_info < (3, 6):
        errors.append(f"Python 3.6+ requis (version actuelle : {sys.version.split()[0]})")

    # Modules stdlib attendus
    for mod in ("socket", "struct", "subprocess", "platform", "random"):
        try:
            __import__(mod)
        except ImportError:
            errors.append(f"Module stdlib manquant : {mod}")

    # Outil de détection de passerelle selon l'OS
    is_win = platform.system() == "Windows"
    if is_win:
        # powershell requis pour lire le DNS configuré
        try:
            subprocess.check_output("powershell -Command exit", shell=True, stderr=subprocess.DEVNULL)
        except Exception:
            errors.append("PowerShell introuvable (requis pour lire le DNS configuré sous Windows)")
    else:
        # ip ou route requis pour détecter la passerelle
        has_ip    = subprocess.call("command -v ip    >/dev/null 2>&1", shell=True) == 0
        has_route = subprocess.call("command -v route >/dev/null 2>&1", shell=True) == 0
        if not has_ip and not has_route:
            errors.append("Aucun outil de routage trouvé (ip ou route requis pour détecter la passerelle)")

    if errors:
        print("Dépendances manquantes :", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        sys.exit(1)

check_deps()

# ─── Couleurs (désactivées sur Windows sans support ANSI) ─────────────────────
IS_WIN = platform.system() == "Windows"
try:
    if IS_WIN:
        os.system("")  # active ANSI sur Windows 10+
    GRN = "\033[0;32m"
    YLW = "\033[1;33m"
    BLU = "\033[0;34m"
    NC  = "\033[0m"
except Exception:
    GRN = YLW = BLU = NC = ""

def hdr(msg):   print(f"\n{BLU}══ {msg} ══{NC}")
def ok(msg):    print(f"{GRN}[+]{NC} {msg}")
def warn(msg):  print(f"{YLW}[!]{NC} {msg}")
def hint(msg):  print(f"    → {msg}")

# ─── Détection de l'IP du routeur ─────────────────────────────────────────────
def detect_gateway():
    try:
        if IS_WIN:
            out = subprocess.check_output("route print 0.0.0.0", shell=True, text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 3 and parts[0] == "0.0.0.0":
                    return parts[2]
        else:
            out = subprocess.check_output("ip route show default", shell=True, text=True, stderr=subprocess.DEVNULL)
            for token in out.split():
                if token not in ("default", "via", "dev", "proto", "metric", "src"):
                    try:
                        socket.inet_aton(token)
                        return token
                    except OSError:
                        pass
    except Exception:
        pass
    return None

# ─── Requête DNS via socket (pas de dépendance externe) ───────────────────────
def dns_query(hostname, server, port=53, timeout=5):
    """Requête DNS A en UDP. Retourne la première IP ou None."""
    try:
        tid = random.randint(0, 65535)
        # Header
        header = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
        # Question : encoder le FQDN
        qname = b""
        for part in hostname.rstrip(".").encode().split(b"."):
            qname += bytes([len(part)]) + part
        qname += b"\x00"
        packet = header + qname + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.connect((server, port))
        sock.send(packet)
        data = sock.recv(512)
        sock.close()

        if len(data) < 12:
            return None
        ancount = struct.unpack(">H", data[4:6])[0]
        if ancount == 0:
            return None

        # Sauter le header (12 bytes) puis la question
        pos = 12
        while pos < len(data):
            if data[pos] == 0:
                pos += 1
                break
            if data[pos] & 0xC0 == 0xC0:
                pos += 2
                break
            pos += data[pos] + 1
        pos += 4  # QTYPE + QCLASS

        # Parcourir les enregistrements de réponse
        for _ in range(ancount):
            if pos >= len(data):
                break
            # Sauter le nom (pointeur ou labels)
            if data[pos] & 0xC0 == 0xC0:
                pos += 2
            else:
                while pos < len(data) and data[pos] != 0:
                    pos += data[pos] + 1
                pos += 1
            if pos + 10 > len(data):
                break
            rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", data[pos:pos+10])
            pos += 10
            if rtype == 1 and rdlen == 4 and pos + 4 <= len(data):
                return ".".join(str(b) for b in data[pos:pos+4])
            pos += rdlen
    except Exception:
        pass
    return None

# ─── Test TCP (port ouvert) ────────────────────────────────────────────────────
def tcp_open(host, port, timeout=3):
    try:
        s = socket.create_connection((host, port), timeout=timeout)
        s.close()
        return True
    except Exception:
        return False

# ─── Lecture du DNS configuré ─────────────────────────────────────────────────
def get_configured_dns():
    if IS_WIN:
        try:
            out = subprocess.check_output(
                'powershell -Command "Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses"',
                shell=True, text=True, stderr=subprocess.DEVNULL)
            addrs = [l.strip() for l in out.splitlines() if l.strip()]
            return addrs[0] if addrs else None
        except Exception:
            return None
    else:
        try:
            with open("/etc/resolv.conf") as f:
                for line in f:
                    if line.startswith("nameserver"):
                        return line.split()[1]
        except Exception:
            pass
        return None

# ─── Main ──────────────────────────────────────────────────────────────────────
def main():
    router = sys.argv[1] if len(sys.argv) > 1 else None

    if not router:
        router = detect_gateway()
    if not router:
        print("Impossible de détecter la passerelle par défaut.")
        print("Passer l'IP en argument : python3 test-adguardhome-client.py <IP_ROUTEUR>")
        sys.exit(1)

    results = {}

    hdr(f"Test AdGuard Home depuis ce client — routeur {router}")

    # ── Test 1 : DNS configuré = routeur ──────────────────────────────────────
    hdr("Test 1 — Serveur DNS configuré")
    dns_cfg = get_configured_dns()
    if dns_cfg == router:
        ok(f"DNS configuré pointe vers le routeur : {dns_cfg}")
        results[1] = True
    else:
        warn(f"DNS configuré : {dns_cfg or 'non détecté'} (attendu : {router})")
        hint("Le serveur DHCP n'a pas fourni l'IP du routeur comme DNS.")
        hint("Vérifier : UCI → dhcp.lan.dhcp_option contient bien '6,<IP_ROUTEUR>'")
        hint(f"Sur le routeur : uci show dhcp | grep dhcp_option")
        results[1] = False

    # ── Test 2 : résolution DNS directe via le routeur ────────────────────────
    hdr("Test 2 — Requête DNS directe vers le routeur")
    res = dns_query("google.com", router)
    if res:
        ok(f"Routeur {router}:53 répond — google.com → {res}")
        results[2] = True
    else:
        warn(f"Routeur {router}:53 ne répond pas aux requêtes DNS")
        hint("AdGuard Home n'écoute peut-être pas encore (démarrage lent).")
        hint("Vérifier sur le routeur : service adguardhome status")
        hint("Logs : logread -e AdGuardHome")
        results[2] = False

    # ── Test 3 : résolution DNS par défaut (sans forcer le serveur) ───────────
    hdr("Test 3 — Résolution DNS par défaut")
    res_default = dns_query("google.com", dns_cfg or router)
    if res_default:
        ok(f"Résolution DNS par défaut fonctionnelle — google.com → {res_default}")
        results[3] = True
    else:
        warn("Résolution DNS par défaut échoue")
        hint("La machine ne résout pas les noms via son DNS configuré.")
        hint("Vérifier la connectivité réseau ou relancer le client DHCP.")
        results[3] = False

    # ── Test 4 : DNAT — bypass 8.8.8.8 doit être intercepté ──────────────────
    hdr("Test 4 — Interception DNAT (bypass 8.8.8.8)")
    res_bypass = dns_query("google.com", "8.8.8.8")
    if res_bypass:
        ok(f"Requête vers 8.8.8.8 interceptée et résolue — google.com → {res_bypass}")
        results[4] = True
    else:
        warn("Requête vers 8.8.8.8 non résolue — règle DNAT absente ou inactive")
        hint("La règle firewall DNAT (port 53 → AdGuard) n'est pas active.")
        hint("Vérifier sur le routeur : uci show firewall | grep -A8 Intercept-DNS")
        hint("Relancer : service firewall restart")
        results[4] = False

    # ── Test 5 : interface web AdGuard accessible ─────────────────────────────
    hdr("Test 5 — Interface web AdGuard Home")
    if tcp_open(router, 8080):
        ok(f"Interface web accessible : http://{router}:8080/")
        results[5] = True
    else:
        warn(f"Interface web non accessible sur {router}:8080")
        hint("AdGuard Home n'est peut-être pas encore démarré.")
        hint(f"Ouvrir l'assistant initial sur : http://{router}:3000/")
        hint("Sur le routeur : service adguardhome start")
        results[5] = False

    # ── Synthèse ──────────────────────────────────────────────────────────────
    labels = {
        1: "DNS configuré (DHCP → routeur)",
        2: "Routeur répond sur :53",
        3: "Résolution DNS par défaut",
        4: "DNAT actif (bypass 8.8.8.8 intercepté)",
        5: "Interface web :8080 accessible",
    }
    passed = sum(1 for v in results.values() if v)
    failed = len(results) - passed

    hdr("Synthèse")
    for n, label in labels.items():
        status = f"{GRN}OK{NC}" if results[n] else f"{YLW}FAIL{NC}"
        print(f"  {n}. {label:<45} {status}")
    print()

    if failed == 0:
        print(f"  {GRN}✔ AdGuard Home opérationnel — {passed}/{len(results)} tests réussis{NC}")
    else:
        print(f"  {YLW}⚠ {failed}/{len(results)} tests en échec — voir les détails ci-dessus{NC}")

    print(f"\n  Query Log : http://{router}:8080/#logs\n")
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
