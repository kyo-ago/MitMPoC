function FindProxyForURL(url, host){
  if (url.match(/\.js$|\/[im].(html|manifest)$/) || ) {
    return "PROXY [local ip address here]:5432; DIRECT";
  }
  return "DIRECT";
}