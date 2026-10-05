// Host-only template test doubles; never included in the APK.
export function getuid() { return 1000; };
export function getspnam(name) { return { pwdp: 'x' }; };
