import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { unzipSync } from "fflate"
import { parseTarget } from "./prepare-xray-sidecar.mjs"

const target = parseTarget(process.argv.slice(2))
if (target === "x86_64-pc-windows-msvc") {
  const root = dirname(dirname(fileURLToPath(import.meta.url)))
  const manifest = JSON.parse(readFileSync(join(root, "tun-sidecar.json"), "utf8"))
  const version = manifest.version
  const name = `sing-box-${version}-windows-amd64.zip`
  const cache = join(root, ".cache", "sing-box", name)
  mkdirSync(dirname(cache), { recursive: true })
  if (!existsSync(cache)) {
    const response = await fetch(`https://github.com/SagerNet/sing-box/releases/download/v${version}/${name}`, { signal: AbortSignal.timeout(60_000) })
    if (!response.ok) throw new Error(`sing-box download failed: ${response.status}`)
    writeFileSync(cache, new Uint8Array(await response.arrayBuffer()))
  }
  const archive = readFileSync(cache)
  if (createHash("sha256").update(archive).digest("hex") !== manifest.sha256) throw new Error("sing-box archive checksum mismatch")
  const entries = unzipSync(archive)
  const binaries = join(root, "src-tauri", "binaries")
  const notices = join(binaries, "tun-notices")
  mkdirSync(notices, { recursive: true })
  const executable = Object.entries(entries).find(([path]) => basename(path) === "sing-box.exe")?.[1]
  const license = Object.entries(entries).find(([path]) => basename(path) === "LICENSE")?.[1]
  if (!executable || !license) throw new Error("sing-box release is incomplete")
  const output = join(binaries, `sing-box-${target}.exe`)
  writeFileSync(output, executable)
  writeFileSync(join(notices, "sing-box-LICENSE.txt"), license)
  writeFileSync(join(notices, "SOURCE.txt"), `Unmodified sing-box ${version}\nSource: https://github.com/SagerNet/sing-box/tree/v${version}\nArchive: https://github.com/SagerNet/sing-box/archive/refs/tags/v${version}.tar.gz\nLicense: GPL-3.0-or-later, with upstream additional terms (see sing-box-LICENSE.txt).\nWintun is embedded by sing-tun; no separate driver download is required.\n`)
  if (process.platform === "win32") execFileSync(output, ["version"], { stdio: "inherit", timeout: 10_000 })
  console.log(`Prepared sing-box ${version} for Windows TUN`)
}
