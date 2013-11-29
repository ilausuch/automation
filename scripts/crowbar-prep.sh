#! /bin/bash
#
# Prepare a host for Crowbar admin node installation.  This takes care
# of making the required repositories available, and performs a few
# other tweaks.
#
# Either scp this script to the host and run it from there, or simply
# take the nuclear detonation approach and pipe it directly to a remote
# bash process:
#
#     cat crowbar-prep.sh | ssh root@$admin_node bash -s -- -d $profile

me=`basename $0`
[ "$me" = bash ] && me=crowbar-prep.sh

: ${ADMIN_IP:=192.168.124.10}
: ${HOST_IP:=192.168.124.1}

HOST_MIRROR_DEFAULT=/data/install/mirrors
: ${HOST_MIRROR:=$HOST_MIRROR_DEFAULT}
HOST_MEDIA_MIRROR_DEAULT=/srv/nfs/media
: ${HOST_MEDIA_MIRROR:=$HOST_MEDIA_MIRROR_DEAULT}

CLOUD_ISO=SUSE-CLOUD-2-x86_64-current.iso
: ${CLOUD_VERSION:=2.0}

SP3_ISO=SLES-11-SP3-DVD-x86_64-current.iso

usage () {
    # Call as: usage [EXITCODE] [USAGE MESSAGE]
    exit_code=1
    if [[ "$1" == [0-9] ]]; then
        exit_code="$1"
        shift
    fi
    if [ -n "$1" ]; then
        echo >&2 "$*"
        echo
    fi

    cat <<EOF >&2
Usage: cat $me | ssh root@ADMIN-NODE bash -s -- [OPTIONS] PROFILE

Profiles:
    nue-host-nfs
        This profile is a hybrid of 'nue-nfs' and 'host-nfs' and is
        probably the best trade-off between convenience and
        flexibility if you are situated in the Nuremberg offices.  It
        takes SLES repos from clouddata, and the SUSE Cloud ISO from
        the VM host ($HOST_IP) via NFS.  This allows you to choose
        which SUSE Cloud build to develop/test against, but eliminates
        the hassle of mirroring SLES repositories.

    nue-nfs
        Mount from clouddata.cloud.suse.de.  This is a no-brainer
        setup which sacrifices flexibility for ease of setup.
        Probably only makes sense if you are within the .nue offices.
        The disadvantage is that you get no choice over which
        SUSE Cloud ISO is used - you just get whatever clouddata
        happens to be serving, and it could change beneath your feet
        without warning :)

    host-nfs
        Mount everything from VM host ($HOST_IP) via NFS (export
        HOST_IP before running if you want to change this IP).  Best
        suited for remote workers and control freaks ;-P  Use this one
        in conjunction with the sync-repos mirroring tool available
        from:

          https://github.com/SUSE/cloud/blob/master/dev-setup/sync-repos

        which by default mirrors to $HOST_MIRROR_DEFAULT, and this
        profile assumes that directory will be NFS-exported to the
        guest (export HOST_MIRROR to override this).  It also assumes
        that the VM host mounts the SP3 and Cloud installation
        sources at $HOST_MEDIA_MIRROR/sles-11-sp3 and
        $HOST_MEDIA_MIRROR/suse-cloud-$CLOUD_VERSION respectively and NFS
        exports both to the guest.

    host-9p
        Similar to 'host-nfs' but mounts from VM host as virtio
        passthrough filesystem.  Assumes that the 9p filesystem is
        exported with the target named 'install', and includes the
        following directories and files (create the .isos as symlinks
        to the real .iso files):

            isos/$SP3_ISO
            isos/$CLOUD_ISO
            mirrors/SLES11-SP3-Pool/sle-11-x86_64/repodata/repomd.xml
            mirrors/SLES11-SP3-Updates/sle-11-x86_64/repodata/repomd.xml

        Surprisingly, this seems to perform a bit slower than the NFS
        approach.

Also adds an entry to /etc/hosts for $ADMIN_IP; export a new value for
ADMIN_IP to override this.

Options:
  -d, --devel-cloud          zypper addrepo Devel:Cloud:$CLOUD_VERSION
  -s, --devel-cloud-staging  zypper addrepo Devel:Cloud:$CLOUD_VERSION:Staging
  -h, --help                 Show this help and exit
EOF
    exit "$exit_code"
}

die () {
    echo >&2 "$*"
    exit 1
}

setup_etc_hosts () {
    if ! long_hostname="`cat /etc/HOSTNAME`"; then
        die "Failed to determine hostname"
    fi
    short_hostname="${long_hostname%%.*}"
    if [ "$short_hostname" = "$long_hostname" ]; then
        die "Failed to determine FQDN for hostname ($short_hostname)"
    fi

    if grep -q "^$ADMIN_IP " /etc/hosts; then
        echo "WARNING: Removing $ADMIN_IP entry already in /etc/hosts:" >&2
        grep "^$ADMIN_IP " /etc/hosts >&2 | sed 's/^/  /'
        sed -i -e "/^$ADMIN_IP /d" /etc/hosts
    fi

    echo "$ADMIN_IP   $long_hostname $short_hostname" >> /etc/hosts
}

common_pre () {
    setup_etc_hosts

    SP3_MOUNTPOINT=/srv/tftpboot/suse-11.3/install
    REPOS_DIR=/srv/tftpboot/repos
    CLOUD_MOUNTPOINT=$REPOS_DIR/Cloud
    POOL_MOUNTPOINT=$REPOS_DIR/SLES11-SP3-Pool
    UPDATES_MOUNTPOINT=$REPOS_DIR/SLES11-SP3-Updates
    mkdir -p $CLOUD_MOUNTPOINT $SP3_MOUNTPOINT $POOL_MOUNTPOINT $UPDATES_MOUNTPOINT
}

is_mounted () {
    mount | grep -q " on $1 "
}

ensure_mount () {
    mountpoint="$1"
    if mount $mountpoint; then
        echo "mounted $mountpoint"
    else
        die "Couldn't mount $mountpoint"
    fi
}

ibs_devel_cloud_shared_sp3_repo () {
    zypper ar -r http://download.suse.de/ibs/Devel:/Cloud:/Shared:/11-SP3/standard/Devel:Cloud:Shared:11-SP3.repo
    zypper mr -p 90 Devel_Cloud_Shared_11-SP3
}

common_post () {
    if [ -n "$mountpoint_9p" ]; then
        is_mounted $mountpoint_9p || ensure_mount $mountpoint_9p
    else
        echo "Not using 9p"
    fi

    for mountpoint in $CLOUD_MOUNTPOINT $SP3_MOUNTPOINT $POOL_MOUNTPOINT $UPDATES_MOUNTPOINT; do
        echo
        if is_mounted $mountpoint; then
            echo "$mountpoint already mounted; umounting ..."
            umount $mountpoint || die "Couldn't umount $mountpoint"
        fi
        ensure_mount $mountpoint
    done

    pattern=cloud_admin
    if zypper -n patterns | grep -q $pattern; then
        pattern_already_installed=yes
    fi

    sc2_repo=SUSE-Cloud-$CLOUD_VERSION
    sp3_repo=SLES-11-SP3
    updates_repo=SLES-11-SP3-Updates

    repos=( $sc2_repo $sp3_repo $updates_repo $ibs_repo )

    for repo in "${repos[@]}"; do
        if zypper lr | grep -q $repo; then
            echo "WARNING: Removing pre-existing $repo repository:" >&2
            zypper rr $repo
            echo
        fi
    done

    zypper ar file://$CLOUD_MOUNTPOINT   $sc2_repo
    zypper ar file://$SP3_MOUNTPOINT     $sp3_repo
    zypper ar file://$UPDATES_MOUNTPOINT $updates_repo

    case "$ibs_repo" in
        Devel_Cloud_${CLOUD_VERSION})
            ibs_devel_cloud_shared_sp3_repo
            zypper ar -r http://download.suse.de/ibs/Devel:/Cloud:/${CLOUD_VERSION}/SLE_11_SP3/Devel:Cloud:${CLOUD_VERSION}.repo
            zypper mr -p 80 Devel_Cloud_${CLOUD_VERSION}
            ;;
        Devel_Cloud_${CLOUD_VERSION}_Staging)
            ibs_devel_cloud_shared_sp3_repo
            zypper ar -r http://download.suse.de/ibs/Devel:/Cloud:/${CLOUD_VERSION}:/Staging/SLE_11_SP3/Devel:Cloud:${CLOUD_VERSION}:Staging.repo
            zypper mr -p 80 Devel_Cloud_${CLOUD_VERSION}_Staging
            ;;
        '')
            ;;
        *)
            die "BUG: unrecognised \$ibs_repo value '$ibs_repo'"
            ;;
    esac

    if [ -n "$pattern_already_installed" ]; then
        echo >&2 "WARNING: $pattern pattern already installed!"
        echo >&2 "You will probably need to upgrade existing packages."
        echo >&2
    fi

    if [ -n "$set_sledgehammer_passwd" ]; then
        sledgehammer_passwd_hook
    fi

    cat <<EOF
Now run the following steps in the admin node.  If it is a VM, it is
probably a good idea to snapshot[1] the VM before at least one of the
steps, if not both.

  zypper -n --gpg-auto-import-keys in -l -t pattern $pattern
  screen -L install-suse-cloud

[1] e.g.: virsh snapshot-create-as pebbles-sp3-admin pre-pattern-install
EOF
}

append_to_fstab () {
    sed -i -e "/^# Auto-generated by $me/,/^End auto-generated section from $me\$/d" /etc/fstab
    (
        echo
        echo "# Auto-generated by $me at `date`"
        # Nicely align columns
        cat | column -t
        echo "# End auto-generated section from $me"
    ) >>/etc/fstab
}

nfs_mount () {
    src="$1" dst="$2"
    echo "$src $dst nfs ro,nolock 0 0"
}

9p_mount () {
    mkdir -p $mountpoint_9p
    echo "install $mountpoint_9p 9p ro,trans=virtio,version=9p2000.L 0 0"
}

iso_mount () {
    src="$1" dst="$2"
    echo "$src $dst iso9660 defaults 0 0"
}

bind_mount () {
    src="$1" dst="$2"
    echo "$src $dst none bind,ro 0 0"
}

# loki_nfs () {
#     loki=loki.suse.de:/vol/euklid/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER
#     nfs_mount $loki/11-SP3-POOL $POOL_MOUNTPOINT
#     nfs_mount $loki/11-SP3      $UPDATES_MOUNTPOINT
# }

clouddata_sle_repos () {
    repos=clouddata.cloud.suse.de:/srv/nfs/repos
    nfs_mount $repos/11-SP3-POOL $POOL_MOUNTPOINT
    nfs_mount $repos/11-SP3      $UPDATES_MOUNTPOINT
}

clouddata_sp3_repo () {
    nfs_mount clouddata.cloud.suse.de:/srv/nfs/suse-11.3/install  $SP3_MOUNTPOINT
}

nue_host_nfs () {
    (
        media_mirrors=$HOST_IP:$HOST_MEDIA_MIRROR
        nfs_mount $media_mirrors/suse-cloud-$CLOUD_VERSION   $CLOUD_MOUNTPOINT
        clouddata_sp3_repo
        clouddata_sle_repos
    ) | append_to_fstab
}

nue_nfs () {
    (
        nfs_mount clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-$CLOUD_VERSION $CLOUD_MOUNTPOINT
        clouddata_sp3_repo
        clouddata_sle_repos
    ) | append_to_fstab
}

host_nfs () {
    (
        media_mirrors=$HOST_IP:$HOST_MEDIA_MIRROR
        nfs_mount $media_mirrors/sles-11-sp3                 $SP3_MOUNTPOINT
        nfs_mount $media_mirrors/suse-cloud-$CLOUD_VERSION   $CLOUD_MOUNTPOINT

        repo_mirrors=$HOST_IP:$HOST_MIRROR
        nfs_mount $repo_mirrors/SLES11-SP3-Pool/sle-11-x86_64    $POOL_MOUNTPOINT
        nfs_mount $repo_mirrors/SLES11-SP3-Updates/sle-11-x86_64 $UPDATES_MOUNTPOINT
    ) | append_to_fstab
}

host_9p () {
    mountpoint_9p=/mnt/9p
    (
        9p_mount
        iso_mount  $mountpoint_9p/isos/$SP3_ISO   $SP3_MOUNTPOINT
        iso_mount  $mountpoint_9p/isos/$CLOUD_ISO $CLOUD_MOUNTPOINT
        bind_mount $mountpoint_9p/mirrors/SLES11-SP3-Pool/sle-11-x86_64    $POOL_MOUNTPOINT
        bind_mount $mountpoint_9p/mirrors/SLES11-SP3-Updates/sle-11-x86_64 $UPDATES_MOUNTPOINT
    ) | append_to_fstab
}

sledgehammer_passwd_hook () {
    mkdir -p /updates/discovering-pre
    hook=/updates/discovering-pre/setpw.hook
    cat >$hook <<EOF
#!/bin/sh
echo "linux" | passwd --stdin root
EOF
    chmod +x $hook
    cat <<EOF

Sledgehammer root password will be set to "linux" to
aid debugging.
EOF
}

parse_opts () {
    ibs_repo=
    set_sledgehammer_passwd=

    while [ $# != 0 ]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -d|--devel-cloud)
                [ -n "$ibs_repo" ] && die "Cannot add multiple IBS repos"
                ibs_repo=Devel_Cloud_$CLOUD_VERSION
                shift
                ;;
            -s|--devel-cloud-staging)
                [ -n "$ibs_repo" ] && die "Cannot add multiple IBS repos"
                ibs_repo=Devel_Cloud_${CLOUD_VERSION}_Staging
                shift
                ;;
            -r|--sledgehammer-root-pw)
                set_sledgehammer_passwd=y
                shift
                ;;
            -*)
                usage "Unrecognised option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# != 1 ]; then
        usage
    fi

    profile="$1"
}

main () {
    parse_opts "$@"

    case "$profile" in
        nue-nfs|nue-host-nfs|host-nfs|host-9p)
            action="${profile//-/_}"
            ;;
        *)
            usage
            ;;
    esac

    common_pre
    $action
    common_post
}

main "$@"
