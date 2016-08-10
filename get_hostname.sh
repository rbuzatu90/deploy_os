#!/bin/bash

WORKDIR="$1"
HOSTSDIR="${WORKDIR}/hosts"
INFODIR="${WORKDIR}/info"

#
# uvtlab-2l
#


if [ ! -d "$WORKDIR" ]; then
    echo "Nu exista ${WORKDIR}" 2>&1
    exit 1
fi

mkdir -p $HOSTSDIR
mkdir -p $INFODIR

HOSTNAME=""
MAC=$(ifconfig eth0 2>/dev/null | grep ether | tr -s " " | cut -d " " -f 3)
IP=$(ip -4 addr show dev eth0 | grep inet | tr -s " " | cut -d " " -f 3)
IP_=$(echo $IP | tr "/" "_") 
NETWORK_=$(ipcalc $IP | grep -i network | tr -s " " | cut -d " " -f 2 | tr "/" "_")

HOSTS=$(ls ${HOSTSDIR} | grep -o -P "\d*" | sort -n)

for HOST in ${HOSTS}; do
    if [ -e ${HOSTSDIR}/$HOST/${MAC} ]; then
	HOSTNAME="uvtlabs-${HOST}"
	break
    fi
done

#exit 1


while true; do
    if [ ! "u${HOSTNAME}" = "u" ]; then
	echo "Hostname already set for host with id ${HOST}" 1>&2
	break
    fi

    MAXIM=$(ls ${HOSTSDIR} | grep -o -P "\d*" | sort -n | tail -1)
    #echo "\"${MAXIM}\""
    if [ "u${MAXIM}" = "u" ]; then
	IDX=1
    else
	IDX=$(expr ${MAXIM} + 1)
    fi
    mkdir ${HOSTSDIR}/${IDX}
    if [ $? -ne 0 ]; then
	continue
    fi

    HOSTNAME="uvtlabs-${IDX}"
    echo "$HOSTNAME" > ${HOSTSDIR}/${IDX}/${MAC}
    break
done

HOST_INFO_DIR=${INFODIR}/${NETWORK_}/${IP_}
mkdir -p ${HOST_INFO_DIR}
lshw -xml > ${HOST_INFO_DIR}/lshw.xml
lshw -xml > ${HOST_INFO_DIR}/lshw.html
    

echo "Generated hostname is: $HOSTNAME" 1>&2

echo ${HOSTNAME}
exit 0
