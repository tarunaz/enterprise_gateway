#!/usr/bin/env bash

if [ "${EG_IMPERSONATION_ENABLED}" = "True" ]; then
        IMPERSONATION_OPTS="sudo PATH=${PATH} -H -E -u ${KERNEL_USERNAME:-UNSPECIFIED}"
        USER_CLAUSE="as user ${KERNEL_USERNAME:-UNSPECIFIED}"
else
        IMPERSONATION_OPTS=""
        USER_CLAUSE="on behalf of user ${KERNEL_USERNAME:-UNSPECIFIED}"
fi

echo
echo "Starting Scala kernel for Spark in Yarn Client mode ${USER_CLAUSE}"
echo

if [ -z "${SPARK_HOME}" ]; then
  echo "SPARK_HOME must be set to the location of a Spark distribution!"
  exit 1
fi

PROG_HOME="$(cd "`dirname "$0"`"/..; pwd)"
KERNEL_ASSEMBLY=`(cd "${PROG_HOME}/lib"; ls -1 toree-assembly-*.jar;)`
TOREE_ASSEMBLY="${PROG_HOME}/lib/${KERNEL_ASSEMBLY}"

# The SPARK_OPTS values during installation are stored in __TOREE_SPARK_OPTS__. This allows values to be specified during
# install, but also during runtime. The runtime options take precedence over the install options.
if [ "${SPARK_OPTS}" = "" ]; then
   SPARK_OPTS=${__TOREE_SPARK_OPTS__}
fi

if [ "${TOREE_OPTS}" = "" ]; then
   TOREE_OPTS=${__TOREE_OPTS__}
fi

# Toree launcher jar path, plus required lib jars (toree-assembly)
JARS="${TOREE_ASSEMBLY}"
# Toree launcher app path
LAUNCHER_JAR=`(cd "${PROG_HOME}/lib"; ls -1 toree-launcher*.jar;)`
LAUNCHER_APP="${PROG_HOME}/lib/${LAUNCHER_JAR}"

set -x
eval exec "${IMPERSONATION_OPTS}" \
     "${SPARK_HOME}/bin/spark-submit" \
     "${SPARK_OPTS}" \
     --jars "${JARS}" \
     --class launcher.ToreeLauncher \
     "${LAUNCHER_APP}" \
     "${TOREE_OPTS}" \
     "${LAUNCH_OPTS}" \
     "$@"
set +x
