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
const swift = readFileSync(
    new URL('../quadlet/josephduffy-co-uk-swift.container', import.meta.url),
    'utf8',
);
const configuration = readFileSync(new URL('../Caddyfile', import.meta.url), 'utf8');
const network = readFileSync(
    new URL('../quadlet/webserver-dual-stack.network', import.meta.url),
    'utf8',
);
const legacyNetwork = readFileSync(
    new URL('../quadlet/webserver.network', import.meta.url),
    'utf8',
);
assert.match(caddy, /^HealthCmd=\/usr\/bin\/curl --silent --output \/dev\/null --show-error --fail --max-time 5 http:\/\/localhost:2019\/config\/$/m);
assert.match(configuration, /^\s*admin localhost:2019$/m);
assert.doesNotMatch(caddy, /^PublishPort=.*2019/m);
for (const publishedPort of [
    '0.0.0.0:80:80/tcp',
    '[::]:80:80/tcp',
    '0.0.0.0:443:443/tcp',
    '[::]:443:443/tcp',
    '0.0.0.0:443:443/udp',
    '[::]:443:443/udp',
]) {
    assert.ok(
        caddy.split('\n').includes(`PublishPort=${publishedPort}`),
        `Missing Caddy published port ${publishedPort}`,
    );
}
assert.match(website, /^EnvironmentFile=\/etc\/webserver\/josephduffy-co-uk\.env$/m);
assert.match(website, /^GlobalArgs=--runtime=runc$/m);
assert.match(caddy, /^GlobalArgs=--runtime=runc$/m);
assert.match(website, /^Network=webserver-dual-stack\.network$/m);
assert.match(swift, /^Network=webserver-dual-stack\.network$/m);
assert.match(caddy, /^Network=webserver-dual-stack\.network$/m);
assert.doesNotMatch(website, /^Sysctl=net\.ipv4\.ip_unprivileged_port_start=/m);
assert.doesNotMatch(caddy, /^Sysctl=net\.ipv4\.ip_unprivileged_port_start=/m);
assert.match(caddy, /^AddCapability=NET_BIND_SERVICE$/m);
assert.match(website, /^Tmpfs=\/app\/.next\/server\/pages:rw,nosuid,nodev,noexec,size=128m,U,mode=0750$/m);
assert.match(
    swift,
    /^HealthCmd=\/usr\/bin\/curl --head --silent --output \/dev\/null --show-error --fail --max-time 5 http:\/\/localhost:8080\/$/m,
);
assert.match(swift, /^EnvironmentFile=\/etc\/webserver\/josephduffy-co-uk-swift\.env$/m);
assert.match(swift, /^GlobalArgs=--runtime=runc$/m);
assert.match(swift, /^ReadOnly=true$/m);
assert.match(swift, /^User=1001:1001$/m);
assert.match(swift, /^PodmanArgs=--memory=4g --cpu-shares=512 --pids-limit=256$/m);
assert.match(website, /^PodmanArgs=--memory=2g --cpu-shares=512 --pids-limit=256$/m);
assert.match(caddy, /^PodmanArgs=--memory=512m --cpu-shares=1024 --pids-limit=128$/m);
assert.match(
    swift,
    /^ConditionPathExists=\/var\/lib\/webserver-deploy\/images\/josephduffy-co-uk-swift\/enabled$/m,
);
assert.doesNotMatch(caddy, /Requires=.*josephduffy-co-uk/);
assert.match(configuration, /^swift\.josephduffy\.co\.uk \{$/m);
assert.match(configuration, /^\s*reverse_proxy josephduffy-co-uk-swift:8080$/m);
assert.match(network, /^Subnet=10\.90\.0\.0\/24$/m);
assert.match(network, /^Gateway=10\.90\.0\.1$/m);
assert.match(network, /^NetworkName=webserver-dual-stack$/m);
assert.match(network, /^IPv6=true$/m);
assert.match(network, /^Subnet=fd9d:7a3b:6f2c:1::\/64$/m);
assert.match(network, /^Gateway=fd9d:7a3b:6f2c:1::1$/m);
assert.match(legacyNetwork, /^Subnet=10\.89\.0\.0\/24$/m);
assert.doesNotMatch(legacyNetwork, /^Subnet=10\.90\.0\.0\/24$/m);
console.log('Website health-command and Caddy liveness configuration tests passed.');
