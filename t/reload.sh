#!/bin/bash

if [ -n "$1" ];then
	PROFILE="$1"
else
   PROFILE=dev
fi
PARENT_PATH=$(dirname $(pwd))
cp -rf ${PARENT_PATH}/lualib/resty `pwd`/lualib/
echo "cp -rf ${PARENT_PATH}/lualib/resty `pwd`/lualib/"
chmod +x sbin/nginx
mkdir -p logs && mkdir -p tmp && mkdir -p pid && mkdir -p conf/ssl
echo "current profile is: "${PROFILE}
echo "./sbin/nginx  -p `pwd`/ -c conf/nginx_${PROFILE}.conf -s reload"
./sbin/nginx -p `pwd`/ -c conf/nginx_${PROFILE}.conf -s reload
