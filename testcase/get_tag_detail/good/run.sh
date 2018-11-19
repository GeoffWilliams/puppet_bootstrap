TOKEN=$(curl -k -X POST --user 'inspect@vsphere.local:Password123!'  https://photon-machine.lan.asio/rest/com/vmware/cis/session | jq -r .value)

curl -v -k --header 'Accept: application/json' --header "vmware-api-session-id: ${TOKEN}" --header "Content-Type: application/json" -X GET "https://photon-machine.lan.asio/rest/com/vmware/cis/tagging/tag/id:urn%3Avmomi%3AInventoryServiceTag%3Ac3c0273b-e888-4354-bc03-07b9771a28cc%3AGLOBAL" > out.txt 2>&1
