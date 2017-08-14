#!/bin/bash

versions=`aws s3api list-object-versions --bucket $1 |jq '.Versions'`
markers=`aws s3api list-object-versions --bucket $1 |jq '.DeleteMarkers'`
let count=`echo $versions |jq 'length'`-1

if [ $count -gt -1 ]; then
  for i in $(seq 0 $count); do
    key=`echo $versions | jq .[$i].Key |sed -e 's/\"//g'`
    versionId=`echo $versions | jq .[$i].VersionId |sed -e 's/\"//g'`
    chronic aws s3api delete-object --bucket $1 --key $key --version-id $versionId
  done
fi

let count=`echo $markers | jq 'length'`

if [ $count -gt 0 ]; then
  for i in $(seq 0 $count); do
    key=`echo $markers | jq .[$i].Key |sed -e 's/\"//g'`
    versionId=`echo $markers | jq .[$i].VersionId |sed -e 's/\"//g'`
    chronic aws s3api delete-object --bucket $1 --key $key --version-id $versionId
  done
fi
chronic aws s3 rb s3://$1 --force
