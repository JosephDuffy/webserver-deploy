import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const website = readFileSync(new URL('../quadlet/josephduffy-co-uk.container', import.meta.url), 'utf8');
const expression = website.match(/^HealthCmd=\/usr\/local\/bin\/node -e "(.*)"$/m)?.[1];
assert.ok(expression, 'Website health command must be executable Node code');

for (const outcome of ['healthy', 'redirect', 'unhealthy', 'unreachable']) {
    let exitCode = 0;
    let exitCalls = 0;
    let calls = 0;
    const context = {
        AbortSignal: {
            timeout(milliseconds) {
                assert.equal(milliseconds, 5000);
                return 'timeout-signal';
            },
        },
        fetch(url, options) {
            calls += 1;
            assert.equal(url, 'http://container-hostname:3000/');
            assert.equal(options.method, 'HEAD');
            assert.equal(options.redirect, 'manual');
            assert.equal(options.signal, 'timeout-signal');
            return outcome === 'unreachable'
                ? Promise.reject(new Error('unreachable'))
                : Promise.resolve({ status: { healthy: 200, redirect: 308, unhealthy: 500 }[outcome] });
        },
        process: { exit(code) { exitCalls += 1; exitCode = code; } },
    };
    context.require = (module) => {
        assert.equal(module, 'node:os');
        return { hostname: () => 'container-hostname' };
    };
    await vm.runInNewContext(expression, context);
    assert.equal(calls, 1);
    assert.equal(exitCalls, 1);
    assert.equal(exitCode, ['healthy', 'redirect'].includes(outcome) ? 0 : 1);
}

const caddy = readFileSync(new URL('../quadlet/caddy.container', import.meta.url), 'utf8');
const configuration = readFileSync(new URL('../Caddyfile', import.meta.url), 'utf8');
const network = readFileSync(new URL('../quadlet/webserver.network', import.meta.url), 'utf8');
assert.match(caddy, /^HealthCmd=\/usr\/bin\/curl --silent --output \/dev\/null --show-error --fail --max-time 5 http:\/\/localhost:2019\/config\/$/m);
assert.match(configuration, /^\s*admin localhost:2019$/m);
assert.doesNotMatch(caddy, /^PublishPort=.*2019/m);
assert.match(website, /^EnvironmentFile=\/etc\/webserver\/josephduffy-co-uk\.env$/m);
assert.match(website, /^GlobalArgs=--runtime=runc$/m);
assert.match(caddy, /^GlobalArgs=--runtime=runc$/m);
assert.doesNotMatch(website, /^Sysctl=net\.ipv4\.ip_unprivileged_port_start=/m);
assert.doesNotMatch(caddy, /^Sysctl=net\.ipv4\.ip_unprivileged_port_start=/m);
assert.match(caddy, /^AddCapability=NET_BIND_SERVICE$/m);
assert.match(website, /^Tmpfs=\/app\/.next\/server\/pages:rw,nosuid,nodev,noexec,size=128m,U,mode=0750$/m);
assert.match(network, /^Subnet=10\.89\.0\.0\/24$/m);
assert.match(network, /^Gateway=10\.89\.0\.1$/m);
console.log('Website health-command and Caddy liveness configuration tests passed.');
