// Clash Verge 全局扩展脚本
// 作用：在国内直连的兜底规则插到 MATCH 前面。
// 不要放进最前面，否则会抢掉广告拦截（国内广告域名会变成直连）。
// 组名不写死：优先用订阅里的直连组，没有就用 DIRECT。

function main(config, profileName) {
  var groups = (config["proxy-groups"] || []).map(function (g) { return g.name; });
  var directGroup = null;
  (config["proxy-groups"] || []).forEach(function (g) {
    var all = g.proxies || [];
    if (!directGroup && all.length === 1 && all[0] === "DIRECT") { directGroup = g.name; }
  });
  if (!directGroup && groups.indexOf("🎯 绕过代理") >= 0) { directGroup = "🎯 绕过代理"; }
  var target = directGroup || "DIRECT";

  var rules = config.rules || [];
  var extra = ["GEOSITE,cn," + target, "GEOIP,CN," + target];
  var idx = -1;
  for (var i = 0; i < rules.length; i++) {
    if (/^MATCH,/.test(rules[i])) { idx = i; break; }
  }
  if (idx < 0) { idx = rules.length; }
  Array.prototype.splice.apply(rules, [idx, 0].concat(extra));
  config.rules = rules;
  return config;
}
