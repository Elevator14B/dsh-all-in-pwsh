/**
 * Boot a DSH host from the installed desktop runtime with a probe row patched
 * in. The runtime location arrives through DSH_PROBE_RUNTIME.
 */
import { pathToFileURL } from 'node:url'

const runtime = process.env.DSH_PROBE_RUNTIME
const home = process.env.DSH_HOME
const anchor = runtime + '/node_modules/@deepseek-ai/dsh/package.json'

const { runProfile } = await import(pathToFileURL(runtime + '/node_modules/@deepseek-ai/dsh/lib/profile-boot.js').href)
const { loadLayeredEnv, loadProfileDirectory } = await import(pathToFileURL(runtime + '/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js').href)

const profile = loadProfileDirectory('dsh', home + '/profiles/web', anchor)
await runProfile({
  environment: loadLayeredEnv('dsh'),
  profile: 'web',
  resolutionMode: 'runtime',
  resolvedProfile: { profile, installAnchor: anchor },
  patchFiles: [process.env.DSH_PROBE_PATCH],
  args: ['--no-open', '--port', '0'],
})
