#!/usr/bin/env python
from __future__ import print_function

import os
import sys

PREFIX = "[N570 ATOM-KERNEL]"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
SRC_DIR = os.path.join(ROOT_DIR, "src", "xnu")


def die(msg):
    print("[atom-kernel-patch] ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def read_text(path):
    with open(path, "rb") as f:
        data = f.read()
    if not isinstance(data, str):
        data = data.decode("utf-8")
    return data


def write_text(path, data):
    if sys.version_info[0] >= 3:
        raw = data.encode("utf-8")
    else:
        raw = data
    with open(path, "wb") as f:
        f.write(raw)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        die("%s: expected exactly one match, found %d" % (label, count))
    return text.replace(old, new, 1)


cpuid_h = os.path.join(SRC_DIR, "osfmk", "i386", "cpuid.h")
cpuid_c = os.path.join(SRC_DIR, "osfmk", "i386", "cpuid.c")
i386_init_c = os.path.join(SRC_DIR, "osfmk", "i386", "i386_init.c")

for path in (cpuid_h, cpuid_c, i386_init_c):
    if not os.path.isfile(path):
        die("missing source file: %s" % path)

# Refuse to stack the patch twice.
combined = read_text(cpuid_h) + read_text(cpuid_c) + read_text(i386_init_c)
if PREFIX in combined or "CPUID_MODEL_ATOM" in read_text(cpuid_h):
    die("N570 patch appears to be already applied; restore src/xnu before reapplying")

# 1) Restore an explicit Atom model constant while preserving the real CPUID model 28.
text = read_text(cpuid_h)
text = replace_once(
    text,
    "#define CPUID_MODEL_NEHALEM\t26\n#define CPUID_MODEL_FIELDS\t30",
    "#define CPUID_MODEL_NEHALEM\t26\n#define CPUID_MODEL_ATOM\t28\n#define CPUID_MODEL_FIELDS\t30",
    "cpuid.h Atom model constant",
)
write_text(cpuid_h, text)

# 2) Accept Atom model 28 without rewriting it to Merom model 15.
# Historical XNU-derived code commonly grouped Atom with CPUFAMILY_INTEL_6_13;
# this is intentionally a first bring-up hypothesis, not a final semantic claim.
text = read_text(cpuid_c)
text = replace_once(
    text,
    "\t\tcase 23:\n\t\t\tcpufamily = CPUFAMILY_INTEL_PENRYN;\n\t\t\tbreak;\n\t\tcase CPUID_MODEL_NEHALEM:",
    "\t\tcase 23:\n\t\t\tcpufamily = CPUFAMILY_INTEL_PENRYN;\n\t\t\tbreak;\n\t\tcase CPUID_MODEL_ATOM:\n\t\t\tcpufamily = CPUFAMILY_INTEL_6_13;\n\t\t\tbreak;\n\t\tcase CPUID_MODEL_NEHALEM:",
    "cpuid.c Atom family acceptance",
)
write_text(cpuid_c, text)

# 3) Add early DEBUG/serial checkpoints and post-kprintf checkpoints.
text = read_text(i386_init_c)
text = replace_once(
    text,
    "#if DEBUG\n\t\tserial_init();\n#endif",
    "#if DEBUG\n\t\tserial_init();\n\t\tDBG(\"[N570 ATOM-KERNEL] vstart: entered boot_args=0x%lx\\n\", (unsigned long)boot_args_start);\n#endif",
    "i386_init.c vstart entry",
)
text = replace_once(
    text,
    "\t\tpostcode(PSTART_PAGE_TABLES);\n\n\t\tIdle_PTs_init();\n\n\t\tfirst_avail = (vm_offset_t)ID_MAP_VTOP(physfree);",
    "\t\tpostcode(PSTART_PAGE_TABLES);\n\n\t\tDBG(\"[N570 ATOM-KERNEL] vstart: before Idle_PTs_init\\n\");\n\t\tIdle_PTs_init();\n\t\tDBG(\"[N570 ATOM-KERNEL] vstart: after Idle_PTs_init physfree=%p\\n\", physfree);\n\n\t\tfirst_avail = (vm_offset_t)ID_MAP_VTOP(physfree);",
    "i386_init.c page-table checkpoints",
)
text = replace_once(
    text,
    "\tcpu_mode_init(current_cpu_datap());\n\n\t/* enable NX/XD */",
    "\tcpu_mode_init(current_cpu_datap());\n\tif (is_boot_cpu)\n\t\tDBG(\"[N570 ATOM-KERNEL] vstart: cpu_mode_init complete cpu=%d\\n\", cpu);\n\n\t/* enable NX/XD */",
    "i386_init.c cpu-mode checkpoint",
)
text = replace_once(
    text,
    "\tunsigned int\tcpus = 0;\n\tboolean_t\tfidn;",
    "\tunsigned int\tcpus = 0;\n\tboolean_t\tfidn;\n\ti386_cpu_info_t *n570_info;",
    "i386_init.c debug info declaration",
)
text = replace_once(
    text,
    "\tDBG(\"i386_init(0x%lx) kernelBootArgs=%p\\n\",\n\t\t(unsigned long)boot_args_start, kernelBootArgs);\n\n\tmaster_cpu = 0;\n\tcpu_init();",
    "\tDBG(\"i386_init(0x%lx) kernelBootArgs=%p\\n\",\n\t\t(unsigned long)boot_args_start, kernelBootArgs);\n\tDBG(\"[N570 ATOM-KERNEL] i386_init: entered boot_args=0x%lx\\n\", (unsigned long)boot_args_start);\n\n\tmaster_cpu = 0;\n\tDBG(\"[N570 ATOM-KERNEL] i386_init: before cpu_init\\n\");\n\tcpu_init();\n\tDBG(\"[N570 ATOM-KERNEL] i386_init: after cpu_init\\n\");",
    "i386_init.c cpu_init checkpoints",
)
text = replace_once(
    text,
    "\t/* setup debugging output if one has been chosen */\n\tPE_init_kprintf(FALSE);",
    "\t/* setup debugging output if one has been chosen */\n\tPE_init_kprintf(FALSE);\n\n\tn570_info = cpuid_info();\n\tkprintf(\"[N570 ATOM-KERNEL] CPUID vendor=%s signature=0x%08x family=%u model=%u extmodel=%u stepping=%u cpufamily=0x%08x\\n\",\n\t\tn570_info->cpuid_vendor, n570_info->cpuid_signature,\n\t\tn570_info->cpuid_family, n570_info->cpuid_model,\n\t\tn570_info->cpuid_extmodel, n570_info->cpuid_stepping,\n\t\tn570_info->cpuid_cpufamily);\n\tkprintf(\"[N570 ATOM-KERNEL] CPUID brand=%s logical/package=%u cores/package=%u features=0x%llx extfeatures=0x%llx\\n\",\n\t\tn570_info->cpuid_brand_string, n570_info->cpuid_logical_per_package,\n\t\tn570_info->cpuid_cores_per_package, n570_info->cpuid_features,\n\t\tn570_info->cpuid_extfeatures);",
    "i386_init.c CPUID diagnostics",
)
text = replace_once(
    text,
    "\ti386_vm_init(maxmemtouse, IA32e, kernelBootArgs);\n\n\tif ( ! PE_parse_boot_argn(\"novmx\", &noVMX, sizeof (noVMX)))",
    "\tkprintf(\"[N570 ATOM-KERNEL] i386_init: before i386_vm_init IA32e=%d maxmem=0x%llx\\n\", IA32e, maxmemtouse);\n\ti386_vm_init(maxmemtouse, IA32e, kernelBootArgs);\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after i386_vm_init\\n\");\n\n\tif ( ! PE_parse_boot_argn(\"novmx\", &noVMX, sizeof (noVMX)))",
    "i386_init.c VM checkpoints",
)
text = replace_once(
    text,
    "\ttsc_init();\n\tpower_management_init();\n\n\tPE_init_platform(TRUE, kernelBootArgs);\n\n\t/* create the console for verbose or pretty mode */\n\tPE_create_console();\n\n\tprocessor_bootstrap();\n\tthread_bootstrap();\n\n\tmachine_startup();",
    "\tkprintf(\"[N570 ATOM-KERNEL] i386_init: before tsc_init\\n\");\n\ttsc_init();\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after tsc_init\\n\");\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: before power_management_init\\n\");\n\tpower_management_init();\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after power_management_init\\n\");\n\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: before PE_init_platform(TRUE)\\n\");\n\tPE_init_platform(TRUE, kernelBootArgs);\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after PE_init_platform(TRUE)\\n\");\n\n\t/* create the console for verbose or pretty mode */\n\tPE_create_console();\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: PE_create_console complete\\n\");\n\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: before processor_bootstrap\\n\");\n\tprocessor_bootstrap();\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after processor_bootstrap\\n\");\n\tthread_bootstrap();\n\tkprintf(\"[N570 ATOM-KERNEL] i386_init: after thread_bootstrap; entering machine_startup\\n\");\n\n\tmachine_startup();",
    "i386_init.c late checkpoints",
)
write_text(i386_init_c, text)

print("[atom-kernel-patch] applied source-level Atom model 28 support")
print("[atom-kernel-patch] cpufamily hypothesis: CPUFAMILY_INTEL_6_13")
print("[atom-kernel-patch] debug prefix: %s" % PREFIX)
print("[atom-kernel-patch] modified:")
print("  %s" % cpuid_h)
print("  %s" % cpuid_c)
print("  %s" % i386_init_c)
print("[atom-kernel-patch] review with: git diff -- kernel/Atom-Kernel-N570/src/xnu/osfmk/i386")
