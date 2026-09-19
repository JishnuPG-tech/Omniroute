#!/usr/bin/env python3
import os
import sys
import re

def fix_migrations(root_dir="/omniroute"):
    print("[FIX] Checking OmniRoute migrations for version collisions...")
    if not os.path.exists(root_dir):
        print(f"[FIX] Path {root_dir} does not exist, skipping.")
        return

    count = 0
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dir_name = os.path.basename(dirpath).lower()
        if dir_name in ("migrations", "drizzle", "prisma", "db", "schema") or "migration" in dir_name:
            version_map = {}
            for fname in sorted(filenames):
                if fname.endswith((".ts", ".js", ".sql", ".mjs")):
                    parts = fname.split("_", 1)
                    if len(parts) > 1 and parts[0].isdigit():
                        ver = int(parts[0])
                        version_map.setdefault(ver, []).append(fname)
            
            if not version_map:
                continue

            highest_ver = max(version_map.keys())
            for ver, f_list in sorted(version_map.items()):
                if len(f_list) > 1:
                    print(f"[FIX] Found collision at version {ver} in {dirpath}: {f_list}")
                    # Keep first, rename subsequent colliding files
                    for extra_f in f_list[1:]:
                        highest_ver += 1
                        old_p = os.path.join(dirpath, extra_f)
                        suffix = extra_f.split("_", 1)[1]
                        new_fname = f"{highest_ver:03d}_{suffix}"
                        new_p = os.path.join(dirpath, new_fname)
                        os.rename(old_p, new_p)
                        print(f"[FIX] Successfully renamed {extra_f} -> {new_fname}")
                        count += 1

    print(f"[FIX] Migration check complete. Resolved {count} version collision(s).")

def fix_rate_limits(root_dir="/omniroute"):
    print("[FIX] Scanning OmniRoute bundles to neutralize 429 login / auth rate limits...")
    if not os.path.exists(root_dir):
        return

    patched_files = 0
    # Scan .next server bundles, server.js, middleware, etc.
    for dirpath, _, filenames in os.walk(root_dir):
        for fname in filenames:
            if fname.endswith((".js", ".mjs", ".cjs")):
                fpath = os.path.join(dirpath, fname)
                try:
                    with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                        content = f.read()

                    modified = False

                    # Pattern 1: rate limiter returning 429 on auth/login or api
                    if "429" in content and ("Too many requests" in content or "Too Many Requests" in content or "rate" in content.lower()):
                        # Neutralize standard rate limiter returns
                        # Replace 429 status code returns with normal flow or pass-through
                        new_content = re.sub(r'status:\s*429', 'status: 200', content)
                        new_content = re.sub(r'\.status\(429\)', '.status(200)', new_content)
                        new_content = re.sub(r'statusCode\s*=\s*429', 'statusCode = 200', new_content)
                        if new_content != content:
                            content = new_content
                            modified = True

                    # Pattern 2: Rate limit threshold overrides
                    # If max attempts is small (e.g. max: 5 or limit: 5), boost to 100000
                    if "rateLimit" in content or "rate-limit" in content or "rateLimiter" in content:
                        new_content = re.sub(r'(max|limit|points)\s*:\s*([1-9]|[1-4][0-9]|50)\b', r'\1: 100000', content)
                        new_content = re.sub(r'(duration|windowMs|window)\s*:\s*(\d+)', r'\1: 1000', new_content)
                        if new_content != content:
                            content = new_content
                            modified = True

                    if modified:
                        with open(fpath, "w", encoding="utf-8") as f:
                            f.write(content)
                        patched_files += 1
                except Exception:
                    pass

    print(f"[FIX] Rate limit scan complete. Neutralized rate limiters in {patched_files} file(s).")

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "/omniroute"
    fix_migrations(target)
    # fix_rate_limits disabled: blind regex replacement across 91 bundle files
    # corrupts Next.js and upstream API responses.

