# Third-party notices

## DeepSeek Harness agent presets

`preset/agent.cordis.yml` is adapted from the agent preset compositions shipped in the DeepSeek Harness repository (<https://github.com/deepseek-ai/deepseek-harness>), under `packages/preset/agent-presets/presets/` — mainly the `ptc` preset, with rows from `minimal`. The plugin rows and their ids, and the persona and tool-description strings the composition keeps, come from there verbatim; the PowerShell shell group, the bridge and bootstrap wiring, and the tool description for the persistent shell are this project's own.

Everything else here — the host plugin, the PowerShell module, the bootstrap script, the installer and the tests — is original work.

DeepSeek Harness is MIT licensed:

    MIT License

    Copyright (c) 2026 DeepSeek

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## Everything else

The rest of this repository is [MIT](LICENSE), Copyright (c) 2026 Huanqi Cao.
