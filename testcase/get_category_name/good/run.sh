TOKEN=$(curl -k -X POST --user 'inspect@vsphere.local:Password123!'  https://photon-machine.lan.asio/rest/com/vmware/cis/session | jq -r .value)

curl -v -k --header 'Accept: application/json' --header "vmware-api-session-id: ${TOKEN}" --header "Content-Type: application/json" -X GET "https://photon-machine.lan.asio/rest/com/vmware/cis/tagging/category/id:urn%3Avmomi%3AInventoryServiceCategory%3A4c0641cd-9a14-45df-bc7c-5ddf138d4601%3AGLOBAL" > out.txt 2>&1
