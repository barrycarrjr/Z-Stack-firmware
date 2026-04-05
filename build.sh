#!/bin/bash
set -e

SDK_DIR=/opt/ti/simplelink_cc13xx_cc26xx_sdk_8_30_01_01/simplelink_cc13xx_cc26xx_sdk_8_30_01_01
CCS_DIR=/opt/ti/ccs
NODE="${CCS_DIR}/ccs/tools/node/node"
APPS_PLUGIN=$(ls -d ${CCS_DIR}/ccs/eclipse/plugins/com.ti.ccs.apps_*)
LAUNCHER="${APPS_PLUGIN}/scripts/app-launcher.js"
WORKSPACE="${SDK_DIR}/workspace"
PROJECTSPEC="${SDK_DIR}/examples/rtos/LP_CC1352P7_4/zstack/znp/tirtos7/ticlang/znp_LP_CC1352P7_4_tirtos7_ticlang.projectspec"

mkdir -p "${WORKSPACE}"

echo "=== Applying firmware patch (SDK source only) ==="
cd "${SDK_DIR}"
git init
git config user.email "build@docker"
git config user.name "build"
git add -A
git commit -q -m "SDK baseline"
git apply /build/firmware.patch --whitespace=fix --exclude='workspace/*'
echo "SDK source patch applied successfully."

echo "=== Verifying preinclude.h ==="
grep "CODE_REVISION_NUMBER\|ZDSECMGR_TC_DEVICE_MAX\|NVOCMP_NVPAGES" "${SDK_DIR}/source/preinclude.h"

echo "=== Importing znp project for CC1352P7 ==="
${NODE} ${LAUNCHER} \
    -workspace "${WORKSPACE}" \
    -application projectImport \
    -ccs.location "${PROJECTSPEC}" \
    -ccs.copyIntoWorkspace \
    -ccs.overwrite 2>&1

echo "=== Patching znp.syscfg (NVS flash layout + CCFG + TX power) ==="
SYSCFG_FILE="${WORKSPACE}/znp_LP_CC1352P7_4_tirtos7_ticlang/znp.syscfg"
# 1. Disable DCDC (Koenkk patch requirement)
sed -i '/CCFG.levelBootloaderBackdoor.*=.*"Active low"/a CCFG.enableDCDC               = false;' "${SYSCFG_FILE}"
# 2. Update NVS flash region to match linker (5 pages × 0x2000 = 0xA000 for 400 devices)
sed -i 's/NVS1.internalFlash.regionSize = 0x4000;/NVS1.internalFlash.regionSize = 0xA000;/' "${SYSCFG_FILE}"
sed -i 's/NVS1.internalFlash.regionBase = 0xAA000;/NVS1.internalFlash.regionBase = 0xA4000;/' "${SYSCFG_FILE}"
# 3. Set TX power (CC1352P7 supports up to 20 dBm)
sed -i '/zstack\.rf\.\$name/a zstack.rf.txPower                            = "10";' "${SYSCFG_FILE}"
echo "SysConfig patched. Verifying critical values:"
grep -E "enableDCDC|regionSize|regionBase|txPower" "${SYSCFG_FILE}"

echo "=== Patching znp_cnf.opts (adding preinclude, coordinator flag, device family) ==="
OPTS_FILE="${WORKSPACE}/znp_LP_CC1352P7_4_tirtos7_ticlang/Stack/Config/znp_cnf.opts"
echo "" >> "${OPTS_FILE}"
echo "-DDeviceFamily_CC13X2X7" >> "${OPTS_FILE}"
echo "-DIS_COORDINATOR" >> "${OPTS_FILE}"
echo "-include ../../../source/preinclude.h" >> "${OPTS_FILE}"

echo "=== Adding nwk_util.c to project ==="
PROJECT_FILE="${WORKSPACE}/znp_LP_CC1352P7_4_tirtos7_ticlang/.project"
sed -i '/<\/linkedResources>/i \
\t\t<link>\
\t\t\t<name>Stack/nwk/nwk_util.c</name>\
\t\t\t<type>1</type>\
\t\t\t<locationURI>COM_TI_SIMPLELINK_CC13XX_CC26XX_SDK_INSTALL_DIR/source/ti/zstack/stack/nwk/nwk_util.c</locationURI>\
\t\t</link>' "${PROJECT_FILE}"
echo "Added nwk_util.c link to .project"

echo "=== Verifying znp_cnf.opts contents ==="
cat "${OPTS_FILE}"
echo ""
echo "=== Verifying preinclude.h defines ==="
echo '#include <stdio.h>' > /tmp/test_defines.c
echo 'int main() {' >> /tmp/test_defines.c
echo '#ifdef FEATURE_NVEXID' >> /tmp/test_defines.c
echo '  printf("FEATURE_NVEXID=%d\n", FEATURE_NVEXID);' >> /tmp/test_defines.c
echo '#else' >> /tmp/test_defines.c
echo '  printf("FEATURE_NVEXID=UNDEFINED\n");' >> /tmp/test_defines.c
echo '#endif' >> /tmp/test_defines.c
echo '#ifdef IS_COORDINATOR' >> /tmp/test_defines.c
echo '  printf("IS_COORDINATOR=defined\n");' >> /tmp/test_defines.c
echo '#else' >> /tmp/test_defines.c
echo '  printf("IS_COORDINATOR=UNDEFINED\n");' >> /tmp/test_defines.c
echo '#endif' >> /tmp/test_defines.c
echo 'printf("NVOCMP_NVPAGES=%d\n", NVOCMP_NVPAGES);' >> /tmp/test_defines.c
echo 'printf("ZDSECMGR_TC_DEVICE_MAX=%d\n", ZDSECMGR_TC_DEVICE_MAX);' >> /tmp/test_defines.c
echo 'return 0; }' >> /tmp/test_defines.c
"${CCS_DIR}/ccs/tools/compiler/ti-cgt-armllvm_4.0.2.LTS/bin/tiarmclang" -E -DIS_COORDINATOR -DDeviceFamily_CC13X2X7 -include "${SDK_DIR}/source/preinclude.h" /tmp/test_defines.c 2>&1 | grep -E "FEATURE_NVEXID|IS_COORDINATOR|NVOCMP_NVPAGES|ZDSECMGR_TC_DEVICE_MAX" || echo "Preprocessor test failed"

echo "=== Building CC1352P7 coordinator (znp) ==="
${NODE} ${LAUNCHER} \
    -workspace "${WORKSPACE}" \
    -application projectBuild \
    -ccs.projects "znp_LP_CC1352P7_4_tirtos7_ticlang" \
    -ccs.configuration default \
    -ccs.buildType full \
    -ccs.listProblems 2>&1

echo "=== Checking map file for NV API symbols ==="
MAP_FILE="${WORKSPACE}/znp_LP_CC1352P7_4_tirtos7_ticlang/default/znp_LP_CC1352P7_4_tirtos7_ticlang.map"
if [ -f "${MAP_FILE}" ]; then
    grep -i "nvexid\|osalNvLength\|MT_SysOsalNvLength\|FEATURE_NV" "${MAP_FILE}" || echo "No NVEXID symbols found in map file"
    cp "${MAP_FILE}" /output/ 2>/dev/null || true
fi

echo "=== Locating output ==="
HEX_FILE=$(find "${WORKSPACE}" -name "*.hex" -path "*CC1352P7*" 2>/dev/null | head -1)

if [ -z "${HEX_FILE}" ]; then
    HEX_FILE=$(find "${WORKSPACE}" -name "*.hex" -path "*znp*" 2>/dev/null | head -1)
fi

if [ -z "${HEX_FILE}" ]; then
    OUT_FILE=$(find "${WORKSPACE}" -name "*.out" -path "*CC1352P7*" 2>/dev/null | head -1)
    if [ -n "${OUT_FILE}" ]; then
        echo "Found ELF but no HEX. Converting..."
        HEX_OUT="/output/CC1352P7_coordinator_400_devices.hex"
        mkdir -p /output
        "${CCS_DIR}/ccs/tools/compiler/ti-cgt-armllvm_4.0.2.LTS/bin/tiarmobjcopy" -O ihex "${OUT_FILE}" "${HEX_OUT}" 2>/dev/null || \
        "${CCS_DIR}/ccs/utils/tiobj2bin/tiobj2bin" "${OUT_FILE}" "${HEX_OUT}" 2>/dev/null || \
        cp "${OUT_FILE}" /output/CC1352P7_coordinator_400_devices.out
        echo "=== SUCCESS ==="
        ls -la /output/
        exit 0
    fi
fi

if [ -n "${HEX_FILE}" ]; then
    echo "Found firmware: ${HEX_FILE}"
    mkdir -p /output
    cp "${HEX_FILE}" /output/CC1352P7_coordinator_400_devices.hex
    echo "=== SUCCESS: /output/CC1352P7_coordinator_400_devices.hex ==="
else
    echo "ERROR: No hex/out file found. Listing build artifacts:"
    find "${WORKSPACE}" -name "*.hex" -o -name "*.out" -o -name "*.o" 2>/dev/null | head -20
    exit 1
fi
