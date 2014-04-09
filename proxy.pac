function FindProxyForURL(url, host){
  if (url.match(/\/(sdk-core-v40\.js|[im]\.(html|manifest))$/) || ) {
    return "PROXY [local ip address here]:5432; DIRECT";
  }
  return "DIRECT";
}