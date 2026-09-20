#!/usr/bin/env python
from __future__ import print_function

import io
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
SOURCE = os.path.join(ROOT_DIR, "src", "xnu", "iokit", "Kernel", "IOService.cpp")
PREFIX = "[N570 ATOM-KERNEL][MATCH]"

REQUIRED_MARKERS = [
    PREFIX + " P>",
    PREFIX + " P<",
    PREFIX + " F>",
    PREFIX + " F<",
    PREFIX + " L>",
    PREFIX + " L<",
    PREFIX + " A>",
    PREFIX + " A<",
    PREFIX + " I>",
    PREFIX + " I<",
    PREFIX + " T>",
    PREFIX + " T<",
    PREFIX + " R>",
    PREFIX + " R<",
    PREFIX + " D>",
    PREFIX + " D<",
    PREFIX + " S>",
    PREFIX + " S<",
]


def die(message):
    sys.stderr.write("[atom-kernel-matchtrace-patch] ERROR: %s\n" % message)
    raise SystemExit(1)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        die("%s anchor count is %d, expected exactly 1" % (label, count))
    return text.replace(old, new, 1)


if not os.path.isfile(SOURCE):
    die("source file not found: %s" % SOURCE)

with io.open(SOURCE, "r", encoding="utf-8") as handle:
    data = handle.read()

present = [marker for marker in REQUIRED_MARKERS if marker in data]
if present:
    missing = [marker for marker in REQUIRED_MARKERS if marker not in data]
    if missing:
        die("partial match-trace patch detected; refusing to modify source")
    print("[atom-kernel-matchtrace-patch] IOKit match tracing is already applied")
    raise SystemExit(0)

helper_old = """static IOService *\t\tgIOResources;
static IOService * \t\tgIOServiceRoot;
"""

helper_new = """static IOService *\t\tgIOResources;
static IOService * \t\tgIOServiceRoot;

/*
 * ASUS Eee PC 1215P / Atom N570 bring-up tracing.
 *
 * Keep this deliberately narrow: IOResources is where the physical machine
 * currently stops, while the "bios" nub should immediately lead into
 * AppleSMBIOS matching on the QEMU control.  Avoid libc string dependencies so
 * this remains safe in the early kernel/IOKit environment.
 */
static bool n570_match_trace_name(const char *left, const char *right)
{
    if (!left || !right)
        return false;

    while (*left && *right && (*left == *right)) {
        left++;
        right++;
    }

    return ((*left == '\\0') && (*right == '\\0'));
}

static bool n570_match_trace_service(IOService *service)
{
    if (!service)
        return false;
    if (service == gIOResources)
        return true;

    return n570_match_trace_name(service->getName(), "bios");
}

static const char *n570_match_trace_class(OSDictionary *table)
{
    const OSSymbol *symbol;

    if (!table)
        return "<none>";

    symbol = OSDynamicCast(OSSymbol, table->getObject(gIOClassKey));
    return symbol ? symbol->getCStringNoCopy() : "<none>";
}
"""

vars_old = """    bool\t\t\tstarted;
"""
vars_new = """    bool\t\t\tstarted;
    bool                        n570PassiveMatched;
    bool                        n570InitOK;
    bool                        n570AttachOK;
"""

family_old = """            // pass in score from property table
            score = IOServiceObjectOrder( table, (void *) gIOProbeScoreKey);

            // do family specific matching
            match = where->matchPropertyTable( table, &score );

            if( !match) {"""

family_new = """            // pass in score from property table
            score = IOServiceObjectOrder( table, (void *) gIOProbeScoreKey);

            // do family specific matching
            if (n570_match_trace_service(where))
                LOG("[N570 ATOM-KERNEL][MATCH] F> %s %s\\n",
                    where->getName(), n570_match_trace_class(table));

            match = where->matchPropertyTable( table, &score );

            if (n570_match_trace_service(where))
                LOG("[N570 ATOM-KERNEL][MATCH] F< %s %s %d\\n",
                    where->getName(), n570_match_trace_class(table), match ? 1 : 0);

            if( !match) {"""

passive_old = """\t    // check the nub matches
\t    if( false == passiveMatch( props, true ))
\t\tcontinue;
"""

passive_new = """\t    // check the nub matches
            if (n570_match_trace_service(this))
                LOG("[N570 ATOM-KERNEL][MATCH] P> %s %s\\n",
                    getName(), n570_match_trace_class(props));

            n570PassiveMatched = passiveMatch( props, true );

            if (n570_match_trace_service(this))
                LOG("[N570 ATOM-KERNEL][MATCH] P< %s %s %d\\n",
                    getName(), n570_match_trace_class(props),
                    n570PassiveMatched ? 1 : 0);

\t    if( false == n570PassiveMatched )
\t\tcontinue;
"""

load_old = """            // Check to see if driver reloc has been loaded.
            needReloc = (false == gIOCatalogue->isModuleLoaded( match ));
            if( needReloc) {"""

load_new = """            // Check to see if driver reloc has been loaded.
            if (n570_match_trace_service(this))
                LOG("[N570 ATOM-KERNEL][MATCH] L> %s %s\\n",
                    getName(), n570_match_trace_class(props));

            needReloc = (false == gIOCatalogue->isModuleLoaded( match ));

            if (n570_match_trace_service(this))
                LOG("[N570 ATOM-KERNEL][MATCH] L< %s %s %d\\n",
                    getName(), n570_match_trace_class(props), needReloc ? 0 : 1);

            if( needReloc) {"""

alloc_old = """                // alloc the driver instance
                inst = (IOService *) OSMetaClass::allocClassWithName( symbol);
    
                if( !inst) {"""

alloc_new = """                // alloc the driver instance
                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] A> %s %s\\n",
                        getName(), symbol->getCStringNoCopy());

                inst = (IOService *) OSMetaClass::allocClassWithName( symbol);

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] A< %s %s %d\\n",
                        getName(), symbol->getCStringNoCopy(), inst ? 1 : 0);
    
                if( !inst) {"""

init_old = """                // init driver instance
                if( !(inst->init( props ))) {
"""

init_new = """                // init driver instance
                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] I> %s %s\\n",
                        getName(), symbol->getCStringNoCopy());

                n570InitOK = inst->init( props );

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] I< %s %s %d\\n",
                        getName(), symbol->getCStringNoCopy(), n570InitOK ? 1 : 0);

                if( !n570InitOK ) {
"""

attach_old = """                // attach driver instance
                if( !(inst->attach( this )))
                        continue;
"""

attach_new = """                // attach driver instance
                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] T> %s %s\\n",
                        getName(), symbol->getCStringNoCopy());

                n570AttachOK = inst->attach( this );

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] T< %s %s %d\\n",
                        getName(), symbol->getCStringNoCopy(), n570AttachOK ? 1 : 0);

                if( !n570AttachOK )
                        continue;
"""

probe_old = """                newInst = inst->probe( this, &score );
                inst->detach( this );"""

probe_new = """                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] R> %s %s\\n",
                        getName(), symbol->getCStringNoCopy());

                newInst = inst->probe( this, &score );

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] R< %s %s %d\\n",
                        getName(), symbol->getCStringNoCopy(), newInst ? 1 : 0);

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] D> %s %s\\n",
                        getName(), symbol->getCStringNoCopy());

                inst->detach( this );

                if (n570_match_trace_service(this))
                    LOG("[N570 ATOM-KERNEL][MATCH] D< %s %s\\n",
                        getName(), symbol->getCStringNoCopy());"""

start_old = """                if( false == started)
                    started = startCandidate( inst );"""

start_new = """                if( false == started) {
                    if (n570_match_trace_service(this))
                        LOG("[N570 ATOM-KERNEL][MATCH] S> %s %s\\n",
                            getName(), inst->getName());

                    started = startCandidate( inst );

                    if (n570_match_trace_service(this))
                        LOG("[N570 ATOM-KERNEL][MATCH] S< %s %s %d\\n",
                            getName(), inst->getName(), started ? 1 : 0);
                }"""

data = replace_once(data, helper_old, helper_new, "trace helper")
data = replace_once(data, vars_old, vars_new, "probeCandidates trace variables")
data = replace_once(data, family_old, family_new, "family match")
data = replace_once(data, passive_old, passive_new, "passive match")
data = replace_once(data, load_old, load_new, "module load")
data = replace_once(data, alloc_old, alloc_new, "driver allocation")
data = replace_once(data, init_old, init_new, "driver init")
data = replace_once(data, attach_old, attach_new, "driver attach")
data = replace_once(data, probe_old, probe_new, "driver probe/detach")
data = replace_once(data, start_old, start_new, "driver start")

for marker in REQUIRED_MARKERS:
    if marker not in data:
        die("post-patch marker missing: %s" % marker)

with io.open(SOURCE, "w", encoding="utf-8", newline="") as handle:
    handle.write(data)

print("[atom-kernel-matchtrace-patch] patched: %s" % SOURCE)
print("[atom-kernel-matchtrace-patch] targets: IOResources and bios")
print("[atom-kernel-matchtrace-patch] marker prefix: %s" % PREFIX)
