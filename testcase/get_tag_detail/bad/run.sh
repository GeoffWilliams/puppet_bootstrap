TOKEN=$(curl -k -X POST --user 'inspect@vsphere.local:Password123!'  https://photon-machine.lan.asio/rest/com/vmware/cis/session | jq -r .value)

curl -v -k --header 'Accept: application/json' --header "vmware-api-session-id: ${TOKEN}" --header "Content-Type: application/json" -X GET "https://photon-machine.lan.asio/rest/com/vmware/cis/tagging/tag/id:nothere" > out.txt 2>&1
