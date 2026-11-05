# ARM64 VDSO Build Configuration
#
# The VDSO gets inserted into the address space of emulated processes, so it
# needs to be compiled as an aarch64 ELF shared library. This requires a cross
# compiler and linker.
#
# On macOS, you need an aarch64 cross-compiler toolchain.
# On Linux, you can use the native compiler if running on arm64, or a cross compiler.

# Try to find an aarch64 compiler
clang = find_program('/usr/local/opt/llvm/bin/clang', '/opt/homebrew/opt/llvm/bin/clang', '/opt/local/bin/clang', 'clang', required: false)

if clang.found()
    # Check if the compiler supports aarch64 target
    check_cc = find_program('./check-cc-arm64.sh', required: false)
    if check_cc.found()
        result = run_command(check_cc, clang, check: false)
        if result.returncode() != 0
            message('ARM64 VDSO: Cross-compiler check failed')
            message(result.stdout() + result.stderr())
        endif
    endif

    lld = find_program(
        'ld.lld',
        '/opt/homebrew/opt/llvm/bin/ld.lld',
        '/usr/local/opt/llvm/bin/ld.lld',
        '/Users/spruceemmanuel/.rustup/toolchains/stable-x86_64-apple-darwin/lib/rustlib/x86_64-apple-darwin/bin/gcc-ld/ld.lld',
        required: false
    )
    fuse_ld = lld.found() ? '-fuse-ld=' + lld.full_path() : '-fuse-ld=lld'
    vdso_compiler = [clang, '-target', 'aarch64-linux-gnu', fuse_ld]

    vdso = custom_target('vdso-arm64',
        input: ['vdso.S', 'vdso.c', 'vdso.lds'],
        output: 'libvdso.so.elf',
        command: vdso_compiler + [
            '-o', '@OUTPUT@', '@INPUT0@', '@INPUT1@',
            '-nostdlib', '-Wl,-T,@INPUT2@', '-Wl,--hash-style,sysv', '-Wl,-soname,linux-vdso.so.1',
            '-shared', '-fPIC', '-ffreestanding'
        ] + get_option('vdso_c_args').split())
else
    # Create a dummy vdso target if no compiler is available
    # This allows building for ARM64 guest even without a vdso
    message('ARM64 VDSO: No suitable cross-compiler found, VDSO will not be built')
    # Create an empty file as placeholder
    vdso = custom_target('vdso-arm64-stub',
        output: 'libvdso.so.elf',
        command: ['touch', '@OUTPUT@'])
endif
