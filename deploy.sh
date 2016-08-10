#!/bin/bash

function log {
	echo "===> $1" 1>&2
}


rm -f /tmp/___test 2>/dev/null
touch /tmp/___test 2>/dev/null
if [ ! -f /tmp/___test ]; then
	mount -n -t tmpfs none /tmp
fi

#mount -n -t tmpfs none /tmp
log Starting deployment solution
RUNDIR=/tmp/.uvt_deployment
PASSFILE="${RUNDIR}/stor_pwd"
TEMPFILE=$(tempfile 2>/dev/null)
WORKDIR=${RUNDIR}/work
IMGDIR=${WORKDIR}/images
NAMEDIR=${WORKDIR}/names

mkdir -p ${RUNDIR}
mkdir -p ${WORKDIR}
mkdir -p ${NAMEDIR}


while true; do
    
    if [ -e ${IMGDIR} ]; then # Daca este deja prezent inseamna ca nu mai trebuie sa montam
	break
    fi
    dialog --insecure --passwordbox "Introducti Parola" 0 0 2> $PASSFILE
    if [ "$?" -ne 0 ]; then # A dat cancel
	dialog --msgbox "Imi pare rau dar trebuie o parola" 0 0
	continue
    fi
    PASSWORD=$(cat $PASSFILE)
    echo -e "username=deployment\npassword=${PASSWORD}\nDOMAIN=CSN" > $PASSFILE
    mount -n -t cifs \
	-o credentials=$PASSFILE,nosetuids,uid=0,noacl \
	//194.102.63.50/deployment_share ${WORKDIR}

    if [ "$?" -eq "0" ] ; then
	break
    fi
    dialog --msgbox "Parola incorecta!" 0 0
done



function save {
	######
	# Determinam ce partitii avem
	######

    PARTITIONS=$(ls /dev/sda* | grep -P '.*\d$')
    PARTITIONS_MENU=$(ls /dev/sda* | grep -P '.*\d$' | awk 'BEGIN { FS="/" }; {  print $3 " " $0  }')

    while true; do
	dialog --inputbox "Introduceti numele salvarii" 0 0 2>${TEMPFILE}
	if [ "$?" -ne "0" ]; then
	    exit 1
	fi
	cat ${TEMPFILE} | grep -v -P '^\w*\s*' && continue
	SAVENAME=$(cat ${TEMPFILE})
	if [ -e ${IMGDIR}/${SAVENAME} ]; then
	    dialog --msgbox "Salvarea cu acest nume deja exista" 0 0
	else
	    SAVEDIR=${IMGDIR}/${SAVENAME}
	    mkdir -p ${SAVEDIR} || exit 1
	    break
	fi
    done
    
    SAVE_CONFIG=${SAVEDIR}/config.sh
    echo > ${SAVE_CONFIG}
    NUM_PARTS=$(sfdisk -d /dev/sda | grep size | grep -v 'Id= 0' | wc -l)
    PART_C_TYPE=$(sfdisk --id /dev/sda 1)
    PART_D_TYPE=$(sfdisk --id /dev/sda 2)
    DISK_IDENTIFIER=$(fdisk -l /dev/sda |grep identifier |awk '{print $3}')
    if [ "u${NUM_PARTS}" = "u0" ]; then # Nici o partitie
	return
    fi
    
    WINDOWS=false
    WINXP=false
    if [ "u${PART_C_TYPE}" = "u7" ]; then # Avem ceva windows
	WINDOWS=true
	WINXP=true
	if [ "u${PART_D_TYPE}" = "u7" ]; then # Este vorba despre win >= Vista
	    WINXP=false
	fi
    fi

    
    LINUX=false
    if [ ${NUM_PARTS} -gt 3 ]; then
	
	fdisk -l /dev/sda | grep -P '^/.*' | tr -s " "  | grep sda3 | grep -i extended >/dev/null
	if [ $? -eq 1 ]; then
	    PLABEL=$(e2label /dev/sda3 2>/dev/null) # Read the label of SDA3
	    if [ "u${PLABEL}" = "uSYSLNX" ]; then # Inseamna ca avem partitia noastra
		fdisk -l /dev/sda | grep -P '^/.*' | tr -s " "  | grep sda4 | grep -i extended>/dev/null # Verificam daca part4 este extinsa
		if [ $? -eq 1 ]; then
		    LINUXDEV=/dev/sda4
		else
		    e2label /dev/sda5 2>/dev/null > /dev/null
		    if [ $? -eq 0 ]; then # Avem ceva EXTFS pe sda5
			LINUXDEV=/dev/sda5
		    else 
			# Presupunem ca avem un EXTFS pe sda6
			LINUXDEV=/dev/sda6
		    fi
		fi

		LASTMNT_DIR=$(dumpe2fs ${LINUXDEV} 2>/dev/null | grep 'mounted' | tr -s " " | cut -d ":" -f 2 | tr -d " ")
		case "u${LASTMNT_DIR}" in
		    "u/target" | "u/")
			LINUX=true
			LINUXID=$(blkid ${LINUXDEV} | grep -P '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -o -i)
			;;
		    "u/target/boot" | "u/boot")
			log "We don't support separate /boot partition"
			;;
		    *)
			fdisk -l
			log "Scenariu nesuportat"
		esac
	    else # Presupunem ca prima partitie disponibila contine sistemul de fisiere / al Linux
	       LINUX=true
	       LINUXDEVIDX=3
	       LINUXDEV=/dev/sda3
	       LINUXID=$(blkid /dev/sda3 | grep -P '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -o -i)
	    fi
	else # We have an extended partition
	    PLABEL=$(e2label /dev/sda5 2>/dev/null) # Read the label of SDA5
	    if [ $? -eq 0 ]; then
		LASTMNT_DIR=$(dumpe2fs /dev/sda5 2>/dev/null | grep 'mounted' | tr -s " " | cut -d ":" -f 2 | tr -d " ")
		case "u${LASTMNT_DIR}" in
		    "u/target" | "u/")
			LINUX=true
			LINUXDEV=/dev/sda5
			LINUXID=$(blkid /dev/sda5 | grep -P '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -o -i)
			;;
		    "u/target/boot" | "u/boot")
			log "We don't support separate /boot partition"
			;;
		    *)
			log "/dev/sda5 is not a root partition"

		esac
	    fi
	fi
    fi
    
    if $LINUX; then
	# Determinam o partitie de swap
	SWAP=false
	SWAPID=$(blkid  | grep -i 'TYPE="swap"' | head -1 | grep -P '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -o -i)
	SWAPDEV=$(blkid  | grep -i 'TYPE="swap"' | head -1 | cut -d ":" -f1)
	if [ $? -eq 0 ]; then
	    SWAP=true
	    log "Found swap on partition ${SWAPDEV} with UUID ${SWAPID}"
	else
	    log "No swap found"
	fi
	log "Found linux in ${LINUXDEV} with UUID=${LINUXID}"
	FSTYPE=$(blkid | grep ${LINUXID} | grep -P ' TYPE="\w*"' -o -i | cut -d '"' -f 2)
	case ${FSTYPE} in
	    "ext2" | "ext3" | "ext4")
		LINUX=true
		;;
	    *)
		log "Unsupported filesystem ${FSTYPE} on ${LINUXDEV}"
		LINUX=false
	esac
    fi

    if $LINUX; then
	if $SWAP; then
	    echo "SWAP=true" >> ${SAVE_CONFIG}
	    echo "SWAPID=${SWAPID}" >> ${SAVE_CONFIG}
	fi
	echo "LINUX_FSTYPE=${FSTYPE}" >> ${SAVE_CONFIG}
	echo "LINUX=true" >> ${SAVE_CONFIG}
	echo "LINUXID=${LINUXID}" >> ${SAVE_CONFIG}

	log "Backing up linux"
	LNXDIR=${RUNDIR}/lnx
	mkdir -p ${LNXDIR} 
	mount -o ro ${LINUXDEV} ${LNXDIR}
	if [ $? -ne 0 ]; then
	    log "Failed to mount ${LINUXDEV}"
	    log "Press RETURN to quit"
	    read
	    return 1
	fi

	cd ${LNXDIR}
	find . -depth -print | cpio -o  | pv | gzip -3 > ${SAVEDIR}/linux_rootfs.cpio.gz
	sync
	umount -l ${LNXDIR}
    else
	echo "LINUX=false" >> ${SAVE_CONFIG}
    fi


    
    
    
    echo "WINXP=${WINXP}" >> ${SAVE_CONFIG}
    PART_C_START=$(sfdisk -d /dev/sda | grep sda1 | cut -d ":" -f 2 | cut -d "," -f 1 | cut -d "=" -f 2)
    PART_C_SIZE=$(sfdisk -d /dev/sda | grep sda1 | cut -d ":" -f 2 | cut -d "," -f 2 | cut -d "=" -f 2)
    PART_C_START=$(expr ${PART_C_START} + 0)
    PART_C_SIZE=$(expr ${PART_C_SIZE} + 0)

    echo "PART_C_START=${PART_C_START}" >> ${SAVE_CONFIG}
    echo "PART_C_SIZE=${PART_C_SIZE}" >> ${SAVE_CONFIG}
    echo "DISK_IDENTIFIER=${DISK_IDENTIFIER}" >> ${SAVE_CONFIG}

    # Orice ar fi salvam prima partitie
    ntfsfix /dev/sda1
    ntfsclone --force -s -o - /dev/sda1 | gzip -1 > ${SAVEDIR}/part_c.ntfs.gz
    sleep 5
    
    if $WINXP; then
	# Salvam informatiile despre prima partitie. 
	# Salvam inceputul si calculam dimensiunea pentru salvare
	echo
    else
	# Salvam startul si dimensiunea exacta a primei partitii
	# Salvam startul si calculam dimensiunea corect pentru a doua partitie
	PART_D_START=$(sfdisk -d /dev/sda | grep sda2 | cut -d ":" -f 2 | cut -d "," -f 1 | cut -d "=" -f 2)
	PART_D_SIZE=$(sfdisk -d /dev/sda | grep sda2 | cut -d ":" -f 2 | cut -d "," -f 2 | cut -d "=" -f 2)
	PART_D_START=$(expr ${PART_D_START} + 0)
	PART_D_SIZE=$(expr ${PART_D_SIZE} + 0)
	echo "PART_D_START=${PART_D_START}" >> ${SAVE_CONFIG}
	echo "PART_D_SIZE=${PART_D_SIZE}" >> ${SAVE_CONFIG}

	log "Salvam si a doua partitie..."
        ntfsfix /dev/sda2
	ntfsclone --force -s -o - /dev/sda2 | gzip -3 > ${SAVEDIR}/part_d.ntfs.gz
    fi
    echo "Press RETURN to continue..."
    read
}

function rest_linux {
    echo "test" > test_rest_linux
	echo "test" > test_rest_linux
    _SAVE_NAMES=$(find ${IMGDIR} -mindepth 1 -type d -exec basename '{}' \;)
    SAVE_NAMES=
    HOSTNAME=$(/opt/uvt/get_hostname.sh $NAMEDIR 2>/dev/null)
    
    if [ $? -ne 0 ]; then
	RND=$(pwgen 4 | head -1)
	HOSTNAME="labs-${RND}"
    fi
    cnt=1
    for i in ${_SAVE_NAMES}; do
	SAVE_NAMES="${SAVE_NAMES} $i $i"
	cnt=$(expr $cnt + 1)
    done
    
    dialog --menu "Selectati salvarea" 0 0 0 \
	${SAVE_NAMES} 2>${TEMPFILE}
    if [ $? -ne 0 ]; then
	return 1
    fi
    SAVE_NAME=$(cat $TEMPFILE)
    SAVE_DIR=$IMGDIR/$SAVE_NAME
    
    if [ ! -f ${SAVE_DIR}/config.sh ]; then
	dialog --msgbox "Salvarea nu exista!" 0 0
    fi

    . ${SAVE_DIR}/config.sh
    if $LINUX; then
	# First create the partition table
	LINUXDEV=/dev/sda5
	
	case ${LINUX_FSTYPE} in
	    "ext4")
		MKFSCMD=mkfs.ext4
		;;
	    "ext3")
		MKFSCMD=mkfs.ext3
		;;
	    "ext2")
		MKFSCMD=mkfs.ext2
		;;
	    *) 
		log "[ERROR] Unsupport filesystem ${LINUX_FSTYPE}"
		log "Press RETURN to continue"
		read
		return
	esac
	
	log "Creating filesystem"
	${MKFSCMD} -U ${LINUXID} /dev/sda5

	mkdir -p ${RUNDIR}/restore_linux
	mount /dev/sda5 ${RUNDIR}/restore_linux
	cd ${RUNDIR}/restore_linux
	pv $SAVE_DIR/linux_rootfs.cpio.gz | gunzip | cpio -id
	
	# Change hostname
	LINUX_HOSTNAME="${HOSTNAME}l"
	echo "${LINUX_HOSTNAME}" > ${RUNDIR}/restore_linux/etc/hostname
	LINUX_HOSTNAME_=$(echo ${LINUX_HOSTNAME} | sed "s/\-/\\\-/")
	sed -i "s/ubuntu/${LINUX_HOSTNAME_}/" ${RUNDIR}/restore_linux/etc/hosts

	#Installing extlinux on Ubuntu
        log "Installing extlinux"
	extlinux --install ${RUNDIR}/restore_linux/
        #echo "say Please wait">>${RUNDIR}/restore_linux/extlinux.conf
        echo "default Linux">>${RUNDIR}/restore_linux/extlinux.conf
	echo "Label Linux">>${RUNDIR}/restore_linux/extlinux.conf
        echo "kernel vmlinuz">>${RUNDIR}/restore_linux/extlinux.conf
        echo "append initrd=initrd.img  root=UUID=${LINUXID} rw quiet">>${RUNDIR}/restore_linux/extlinux.conf
    fi

    log "Press RETURN to continue"
    read
    return
}

function restore {
    _SAVE_NAMES=$(find ${IMGDIR} -mindepth 1 -type d -exec basename '{}' \;)
    SAVE_NAMES=
    HOSTNAME=$(/opt/uvt/get_hostname.sh $NAMEDIR 2>/dev/null)
    
    if [ $? -ne 0 ]; then
	RND=$(pwgen 4 | head -1)
	HOSTNAME="labs-${RND}"
    fi
    cnt=1
    for i in ${_SAVE_NAMES}; do
	SAVE_NAMES="${SAVE_NAMES} $i $i"
	cnt=$(expr $cnt + 1)
    done
    
    dialog --menu "Selectati salvarea" 0 0 0 \
	${SAVE_NAMES} 2>${TEMPFILE}
    if [ $? -ne 0 ]; then
	return 1
    fi
    SAVE_NAME=$(cat $TEMPFILE)
    SAVE_DIR=$IMGDIR/$SAVE_NAME
    
    if [ ! -f ${SAVE_DIR}/config.sh ]; then
	dialog --msgbox "Salvarea nu exista!" 0 0
    fi
    
    . ${SAVE_DIR}/config.sh
    log "Rad inceputul discului"
    dd if=/dev/zero of=/dev/sda bs=1M count=512 oflag=direct 2>/dev/null
    sync
    #echo "${PART_C_START} ${PART_C_SIZE} 7 *" | sfdisk /dev/sda
    PART_C_END=$(( ${PART_C_START} + ${PART_C_SIZE} - 1 ))
    PART_D_END=$(( ${PART_D_START} + ${PART_D_SIZE} - 1 ))
    fdisk /dev/sda <<EOF
o
x
i
${DISK_IDENTIFIER}
r
n
p
1
${PART_C_START}
${PART_C_END}
t
7
w
EOF
    sync 
    sleep 2
    ${WINXP} || fdisk /dev/sda <<EOF
n
p
2
${PART_D_START}
+80G
t
2
7
w
EOF
    sync
    sleep 2

    SYSLNXIDX=3
    $WINXP && SYSLNXIDX=2
    fdisk /dev/sda <<EOF
n
p
${SYSLNXIDX}

+500M
a
1
w
EOF
    sync
    sleep 2

    log "Restoring windows"
    CNT=1
    while true; do
	set +o pipefail
	cat ${SAVE_DIR}/part_c.ntfs.gz | gunzip | ntfsclone -r -O /dev/sda1 - 
	COD=$?
	if [ ${COD} -ne 0 ]; then
	    CNT=$(expr $CNT + 1)
	    if [ $CNT -gt 5 ]; then
		log " Failed restoring part_c. Press RETURN to exit"
		read 
		return 1	
	    else
		set -o pipefail
		echo "Failed restoring. CODE: ${COD}. Trying again"
		sleep 5
		continue
	    fi
	fi
	
	set -o pipefail
	break
    done

    CNT=1
 
    if ! $WINXP; then
	while true; do
	    set +o pipefail
	    cat $SAVE_DIR/part_d.ntfs.gz | gunzip | ntfsclone -r -O /dev/sda2 -
	    COD=$?
	    set -o pipefail
	    if [ $COD -ne 0 ]; then
		CNT=$(expr $CNT + 1)
		if [ $CNT -gt 5 ]; then
		    log "Eror restoring part_d. Press RETURN to exit"
		    read
		    return 1
		else
		    log "Error writing part_d. Code: ${COD}. Tring again"
		    sleep 5
		    continue
		fi
	    else
		break
	    fi
	done
       
    fi

    log "Installing standard MBR"
    dd if=/usr/share/syslinux/mbr.bin of=/dev/sda bs=512 count=1 2>/dev/null
    printf '\3' | cat /usr/share/syslinux/altmbr.bin - | dd bs=440 count=1 iflag=fullblock conv=notrunc of=/dev/sda

    SYSLNXPART=/dev/sda3
    $WINXP && SYSLNXPART=/dev/sda2
    log "Installing syslinux..."
    mkfs.ext2 -L SYSLNX ${SYSLNXPART}
    mkdir -p ${RUNDIR}/mnt
    mount -n ${SYSLNXPART} ${RUNDIR}/mnt
    mkdir ${RUNDIR}/mnt/syslinux
    cp -rp /usr/share/syslinux/* ${RUNDIR}/mnt/syslinux
    extlinux --install ${RUNDIR}/mnt/syslinux
    
    echo "Default vesamenu.c32" > ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "Menu background uvt2.png" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "Timeout 150" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "prompt 0" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "allowoptions 0" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg    
    echo "noescape 0" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    
    echo "Label Linux"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "com32 chain.c32"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg    
    echo "append hd0 5"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg    
    
    echo "Label Windows"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "com32 chain.c32"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg    
    echo "append hd0 1"  >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    
    echo "Label Netboot" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "kernel ipxe.lkrn" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "menu passwd \$1\$jhfbsjdh\$2dEvxepcJVfzxM7mvhgP90" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU PASSPROMPT Introduceti parola" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU PASSWORDMARGIN 25" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU PASSWORDROW 10" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU COLOR PWDHEADER 34;42 #ffffffff #00000000 std" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU COLOR PWDENTRY 32;44 #ffffffff #00000000 std" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU COLOR PWDHEADER 46SSWORDMARGIN 25" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg
    echo "MENU COLOR PWDBORDER 34;41 #00000000 #00000000 std" >> ${RUNDIR}/mnt/syslinux/syslinux.cfg


    umount -n ${RUNDIR}/mnt



      # Set Windows ComputerName
        WINDOWS_HOSTNAME="${HOSTNAME}w"
        WINDOWS_HOSTNAME_=$(echo ${WINDOWS_HOSTNAME} | sed "s/\-/\\\-/")
        mkdir -p ${RUNDIR}/mnt/
        mkdir -p ${RUNDIR}/mnt/win_fix
	mount.ntfs-3g /dev/sda2 ${RUNDIR}/mnt/win_fix
        log "Modifing unattend.xml !"
        sed -i \
            "s/XXUVH543IXQQ/${WINDOWS_HOSTNAME_}/" \
            ${RUNDIR}/mnt/win_fix/Windows/Panther/unattend.xml
        sync
        umount ${RUNDIR}/mnt/win_fix

    if $LINUX; then
	# First create the partition table
	LINUXDEV=/dev/sda5
	
	# Create the extended partition
	if $WINXP; then
	    echo -e "n\ne\n3\n\n\nw\n" | fdisk /dev/sda
	else
	    echo -e "n\ne\n\n\nw\n" | fdisk /dev/sda
	fi
	sync ; sleep 4
	log "Creating linux partition"
	echo -e "n\n\n+20G\nw\n" | fdisk /dev/sda
	sync ; sleep 4
	echo -e "n\n\n+4G\nt\n6\n82\nw\n" | fdisk /dev/sda
	sync ; sleep 3

	log "Formating swap"
	if $SWAP; then
	    mkswap -U ${SWAPID} /dev/sda6 
	fi

	case ${LINUX_FSTYPE} in
	    "ext4")
		MKFSCMD=mkfs.ext4
		;;
	    "ext3")
		MKFSCMD=mkfs.ext3
		;;
	    "ext2")
		MKFSCMD=mkfs.ext2
		;;
	    *) 
		log "[ERROR] Unsupport filesystem ${LINUX_FSTYPE}"
		log "Press RETURN to continue"
		read
		return
	esac

	log "Creating filesystem"
	${MKFSCMD} -U ${LINUXID} /dev/sda5

	mkdir -p ${RUNDIR}/restore_linux
	mount /dev/sda5 ${RUNDIR}/restore_linux
	cd ${RUNDIR}/restore_linux
	pv $SAVE_DIR/linux_rootfs.cpio.gz | gunzip | cpio -id
	
	# Change hostname
	LINUX_HOSTNAME="${HOSTNAME}l"
	echo "${LINUX_HOSTNAME}" > ${RUNDIR}/restore_linux/etc/hostname
	LINUX_HOSTNAME_=$(echo ${LINUX_HOSTNAME} | sed "s/\-/\\\-/")
	sed -i "s/ubuntu/${LINUX_HOSTNAME_}/" ${RUNDIR}/restore_linux/etc/hosts

	#Installing extlinux on Ubuntu
        log "Installing extlinux"
	extlinux --install ${RUNDIR}/restore_linux/
        #echo "say Please wait">>${RUNDIR}/restore_linux/extlinux.conf
        echo "default Linux">>${RUNDIR}/restore_linux/extlinux.conf
	echo "Label Linux">>${RUNDIR}/restore_linux/extlinux.conf
        echo "kernel vmlinuz">>${RUNDIR}/restore_linux/extlinux.conf
        echo "append initrd=initrd.img  root=UUID=${LINUXID} rw quiet">>${RUNDIR}/restore_linux/extlinux.conf

        # Set Windows ComputerName
	WINDOWS_HOSTNAME="${HOSTNAME}w"
	WINDOWS_HOSTNAME_=$(echo ${WINDOWS_HOSTNAME} | sed "s/\-/\\\-/")
	mkdir -p ${RUNDIR}/win_fix
	mount.ntfs-3g /dev/sda2 ${RUNDIR}/win_fix
	sync
	umount ${RUNDIR}/win_fix

	# For installing grub
	#mount -o bind /dev ${RUNDIR}/restore_linux/dev
	#chroot ${RUNDIR}/restore_linux /usr/sbin/grub-install --force /dev/sda5 2>/dev/null
	#umount ${RUNDIR}/restore_linux/dev
	sync
	cd
	umount ${RUNDIR}/restore_linux
    fi

    log "Press RETURN to continue"
    read
    return
}


dialog --textbox /opt/uvt/start_msg.txt 0 0

while true; do
    dialog --menu "Selectati Operatia" 0 0 0\
	Save "Salvare Imagine" \
	RestoreLinux "Restore Linux" \
	Restore "Restaurare Imagine" \
	Exit "Iesire" 2>${TEMPFILE} \
	Reboot "Reboot" || exit 1


    OPTION=$(cat ${TEMPFILE})
    
    case "$OPTION" in
	"Save")
	    save
	    ;;
        "RestoreLinux")
             rest_linux
             ;;
	"Restore")
	    restore
	    ;;
	"Exit")
	    echo
	    log "Mi-a facut placere sa lucrez cu tine!"
	    exit 0
	    ;;
	"Reboot")
		dialog --pause 'Reporniti Calculatorul ? \n\n\n' 0 0 10
		if [ $? -eq 0 ]; then
			reboot -f
		fi
	    ;;
	*)
	    dialog --msgbox "Optiune Nesuportata"
    esac
   
done
 
#test
