/**
 * Integration runner for dsh-all-in-pwsh.
 *
 * Boots the real DSH runtime once per probe against a throwaway DSH home, with
 * the preset installed by this repository's installer. Needs the desktop DSH
 * runtime; probes marked "model" additionally need a usable model route, so
 * they only run with --with-model.
 *
 * Usage:
 *   node tests/integration/run.cjs [--probe all|cold|lifecycle] [--with-model]
 *   DSH_PROBE_RUNTIME=<app.asar/dsh> DSH_PROBE_EXE=<Electron exe> node run.cjs
 */
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const cp = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..', '..')
const args = process.argv.slice(2)
const withModel = args.includes('--with-model')
const requested = (args.find(a => a.startsWith('--probe=')) || '--probe=all').split('=')[1]
const probes = [
  { name: 'cold', file: 'probes/cold.mjs', model: false, timeoutMs: 240000 },
  { name: 'lifecycle', file: 'probes/lifecycle.mjs', model: false, timeoutMs: 420000 },
  { name: 'model', file: 'probes/model.mjs', model: true, timeoutMs: 900000 },
]
const selected = requested === 'all' ? probes : probes.filter(p => p.name === requested)
if (selected.length === 0) {
  console.error('unknown probe: ' + requested + ' (known: ' + probes.map(p => p.name).join(', ') + ', all)')
  process.exit(2)
}

/** Locate the installed desktop runtime, or explain why the suite cannot run. */
function resolveRuntime() {
  const explicit = process.env.DSH_PROBE_RUNTIME
  const explicitExe = process.env.DSH_PROBE_EXE
  if (explicit && explicitExe) return { runtime: explicit, exe: explicitExe }
  const local = process.env.LOCALAPPDATA
  if (!local) return undefined
  const base = path.join(local, 'Programs', 'DeepSeek Harness')
  const exe = path.join(base, 'DeepSeek Harness.exe')
  // app.asar is a FILE to plain Node; only the Electron runtime can read the
  // tree inside it, so existence of the archive is what is checked here.
  const archive = path.join(base, 'resources', 'app.asar')
  if (fs.existsSync(archive) && fs.existsSync(exe)) return { runtime: path.join(archive, 'dsh'), exe }
  return undefined
}

const resolved = resolveRuntime()
if (resolved === undefined) {
  console.log('SKIP: no DSH desktop runtime found.')
  console.log('      Set DSH_PROBE_RUNTIME to <...>/resources/app.asar/dsh and')
  console.log('      DSH_PROBE_EXE to the Electron/desktop executable, then re-run.')
  process.exit(0)
}

const PROFILE_PACKAGE = {
  name: 'dsh-profile-web',
  private: true,
  dependencies: {},
  dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app'] } },
}
const PROFILE_CORDIS = '# dsh profile root: an empty entry list; the tree is composed as patches.\n[]\n'
const PROFILE_PATCH = '# Profile patch layer, applied after every bundle layer.\n[]\n'
const PROFILE_WORKSPACE = 'packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n'

function prepareHome(root, copyCredentials) {
  const home = path.join(root, 'dsh-home')
  fs.mkdirSync(home, { recursive: true })
  const profileDir = path.join(home, 'profiles', 'web')
  fs.mkdirSync(path.join(profileDir, 'node_modules'), { recursive: true })
  fs.mkdirSync(path.join(profileDir, '.dsh-module-fallback', 'node_modules'), { recursive: true })
  fs.writeFileSync(path.join(profileDir, 'package.json'), JSON.stringify(PROFILE_PACKAGE, null, 2))
  fs.writeFileSync(path.join(profileDir, 'cordis.yml'), PROFILE_CORDIS)
  fs.writeFileSync(path.join(profileDir, 'cordis.patch.yml'), PROFILE_PATCH)
  fs.writeFileSync(path.join(profileDir, 'pnpm-workspace.yaml'), PROFILE_WORKSPACE)
  if (copyCredentials) {
    for (const name of ['settings.yaml', '.credentials.yaml']) {
      const source = path.join(os.homedir(), '.dsh', name)
      if (fs.existsSync(source)) fs.copyFileSync(source, path.join(home, name))
    }
  }
  return home
}

function runProbe(probe) {
  return new Promise(resolve => {
    const root = path.join(os.tmpdir(), 'dsh-all-in-pwsh-it-' + probe.name + '-' + Date.now())
    fs.mkdirSync(root, { recursive: true })
    const copyCredentials = withModel && probe.model
    const home = prepareHome(root, copyCredentials)
    cp.execFileSync('pwsh', ['-NoLogo', '-NoProfile', '-File', path.join(repoRoot, 'install.ps1'), '-DshHome', home], { stdio: 'pipe' })
    const patch = path.join(root, 'probe.patch.yml')
    fs.writeFileSync(patch, '- insert:\n    - id: dsh-probe\n      name: ' + JSON.stringify(path.join(__dirname, probe.file).replaceAll('\\', '/')) + '\n')
    const cwd = path.join(root, 'workspace')
    fs.mkdirSync(cwd, { recursive: true })
    const reportPath = path.join(root, 'report.json')
    const env = Object.assign({}, process.env, {
      DSH_HOME: home,
      DSH_PERMISSION_MODE: 'danger-full-access',
      DSH_PROBE_RUNTIME: resolved.runtime,
      DSH_PROBE_PATCH: patch,
      PROBE_OUT: reportPath,
      PROBE_RUNTIME: resolved.runtime,
      PROBE_PRESET: 'dsh-all-in-pwsh',
      PROBE_TOKEN: probe.name,
      ELECTRON_RUN_AS_NODE: '1',
    })
    const out = fs.openSync(path.join(root, 'stdout.log'), 'w')
    const err = fs.openSync(path.join(root, 'stderr.log'), 'w')
    const child = cp.spawn(resolved.exe, [path.join(__dirname, 'boot.mjs')], { env, cwd, stdio: ['ignore', out, err], windowsHide: true })
    const timer = setTimeout(() => { child.kill(); console.log('  TIMEOUT after ' + probe.timeoutMs + 'ms') }, probe.timeoutMs)
    child.on('exit', code => {
      clearTimeout(timer)
      // Never leave a copied credential behind, even when the probe fails.
      if (copyCredentials) fs.rmSync(path.join(home, '.credentials.yaml'), { force: true })
      let report
      try { report = JSON.parse(fs.readFileSync(reportPath, 'utf8')) } catch { report = undefined }
      resolve({ root, code, report })
    })
  })
}

async function main() {
  let failed = 0
  for (const probe of selected) {
    if (probe.model && !withModel) {
      console.log('SKIP  ' + probe.name + ' (drives a real model; re-run with --with-model)')
      continue
    }
    const { root, code, report } = await runProbe(probe)
    if (report === undefined) {
      console.log('FAIL  ' + probe.name + ' (no report; artifacts in ' + root + ')')
      failed += 1
      continue
    }
    const checks = report.checks || []
    const bad = checks.filter(c => !c.ok)
    for (const check of checks) console.log((check.ok ? 'PASS  ' : 'FAIL  ') + probe.name + '.' + check.name)
    if (report.error !== undefined) console.log('      error: ' + String(report.error).split('\n')[0])
    if (checks.length === 0 || bad.length > 0 || report.error !== undefined || code !== 0) {
      console.log('FAIL  ' + probe.name + ' (exit ' + code + ', artifacts in ' + root + ')')
      failed += 1
    }
    else {
      console.log('OK    ' + probe.name + ' (' + checks.length + ' checks)')
      fs.rmSync(root, { recursive: true, force: true })
    }
  }
  if (failed > 0) {
    console.log('')
    console.log('FAILED: ' + failed + ' probe(s)')
    process.exit(1)
  }
  console.log('')
  console.log('Integration checks passed.')
}

main().catch(error => { console.error(error); process.exit(1) })
