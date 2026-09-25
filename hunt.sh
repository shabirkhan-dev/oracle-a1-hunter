#!/usr/bin/env bash
# Try to create an Oracle Cloud "Always Free" Ampere A1 machine, and stop once one exists.
#
# Free A1 capacity is often full in popular regions ("Out of host capacity"). This asks once for
# each availability domain and each size (largest first), then exits. Run it on a schedule (the
# GitHub Actions workflow here does, every 10 minutes) until a slot opens.
#
# Needs the OCI CLI signed in (~/.oci/config, or the workflow's secrets) and jq.
#
# Exit codes: 0 = the machine exists (made now or before); 2 = no capacity this time, try later;
# anything else = a real problem worth reading.
set -euo pipefail

NAME="${INSTANCE_NAME:-grid}"
SHAPE="VM.Standard.A1.Flex"
# OCPUs:memory (GB) to try, largest first. The free allowance is 4 OCPUs and 24 GB in total.
SIZES="${SIZES:-4:24 2:12 1:6}"
BOOT_GB="${BOOT_GB:-100}"
TENANCY="${OCI_TENANCY_OCID:?set OCI_TENANCY_OCID}"
COMPARTMENT="${OCI_COMPARTMENT_OCID:-$TENANCY}"
SSH_KEY_FILE="${SSH_KEY_FILE:?set SSH_KEY_FILE to your public key}"
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_DATA="${USER_DATA_FILE:-$HERE/cloud-init.yaml}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Writes a GitHub Actions output when running there; harmless elsewhere.
output() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >>"$GITHUB_OUTPUT" || true; }

existing() {
	oci compute instance list --compartment-id "$COMPARTMENT" --display-name "$NAME" --all |
		jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty'
}

public_ip() {
	oci compute instance list-vnics --instance-id "$1" | jq -r '.data[0]."public-ip" // "none yet"'
}

# A public subnet to put the machine in: OCI_SUBNET_OCID, or one made here once (grid-vcn).
subnet() {
	if [ -n "${OCI_SUBNET_OCID:-}" ]; then
		echo "$OCI_SUBNET_OCID"
		return
	fi
	local vcn
	vcn="$(oci network vcn list --compartment-id "$COMPARTMENT" --display-name grid-vcn --all | jq -r '.data[0].id // empty')"
	if [ -z "$vcn" ]; then
		log "making a network for it (grid-vcn)"
		local made
		made="$(oci network vcn create --compartment-id "$COMPARTMENT" --display-name grid-vcn \
			--cidr-blocks '["10.0.0.0/16"]' --dns-label gridvcn --wait-for-state AVAILABLE)"
		vcn="$(jq -r '.data.id' <<<"$made")"
		local route_table igw
		route_table="$(jq -r '.data."default-route-table-id"' <<<"$made")"
		igw="$(oci network internet-gateway create --compartment-id "$COMPARTMENT" --vcn-id "$vcn" \
			--is-enabled true --display-name grid-igw --wait-for-state AVAILABLE | jq -r '.data.id')"
		oci network route-table update --rt-id "$route_table" --force \
			--route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" >/dev/null
	fi
	local found
	found="$(oci network subnet list --compartment-id "$COMPARTMENT" --vcn-id "$vcn" --all | jq -r '.data[0].id // empty')"
	if [ -z "$found" ]; then
		found="$(oci network subnet create --compartment-id "$COMPARTMENT" --vcn-id "$vcn" \
			--display-name grid-subnet --cidr-block 10.0.0.0/24 --dns-label grid \
			--wait-for-state AVAILABLE | jq -r '.data.id')"
	fi
	echo "$found"
}

image() {
	oci compute image list --compartment-id "$COMPARTMENT" --operating-system "Canonical Ubuntu" \
		--operating-system-version "24.04" --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all |
		jq -r '.data[0].id // empty'
}

main() {
	local id
	id="$(existing)"
	if [ -n "$id" ]; then
		log "already there: $NAME ($id), public IP $(public_ip "$id")"
		output created false
		output exists true
		exit 0
	fi

	local image_id subnet_id
	image_id="$(image)"
	[ -n "$image_id" ] || {
		log "no Ubuntu 24.04 image for $SHAPE in this region"
		exit 1
	}
	subnet_id="$(subnet)"

	local domains
	mapfile -t domains < <(oci iam availability-domain list --compartment-id "$TENANCY" | jq -r '.data[].name')

	local user_data=()
	[ -f "$USER_DATA" ] && user_data=(--user-data-file "$USER_DATA")

	for size in $SIZES; do
		local ocpus="${size%%:*}" memory="${size##*:}"
		for domain in "${domains[@]}"; do
			log "asking for $ocpus OCPU / ${memory} GB in $domain"
			local result
			# --no-retry: the CLI would otherwise retry "out of capacity" by itself for minutes, and
			# those retries are what get the account rate limited. The schedule is the retry.
			if result="$(oci compute instance launch --no-retry --compartment-id "$COMPARTMENT" \
				--availability-domain "$domain" --shape "$SHAPE" \
				--shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$memory}" \
				--image-id "$image_id" --subnet-id "$subnet_id" --assign-public-ip true \
				--display-name "$NAME" --boot-volume-size-in-gbs "$BOOT_GB" \
				--ssh-authorized-keys-file "$SSH_KEY_FILE" "${user_data[@]}" 2>&1)"; then
				id="$(jq -r '.data.id' <<<"$result")"
				log "got it: $NAME ($id), $ocpus OCPU / ${memory} GB in $domain"
				output created true
				output exists true
				output detail "$ocpus OCPU / ${memory} GB in $domain"
				exit 0
			fi
			case "$result" in
			*"Out of host capacity"* | *"out of host capacity"*) log "  no capacity" ;;
			*TooManyRequests* | *'"status": 429'*) log "  rate limited; stopping this round" && exit 2 ;;
			*LimitExceeded* | *QuotaExceeded* | *"service limit"*)
				log "  over the free limit at this size (something else may be using it); trying smaller"
				;;
			*)
				log "  failed: $(grep -m1 -E '"message"|Error' <<<"$result" || echo "$result" | head -3)"
				exit 1
				;;
			esac
		done
	done
	log "no free capacity anywhere this time; the next run tries again"
	output created false
	output exists false
	exit 2
}

main "$@"
