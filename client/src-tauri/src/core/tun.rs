use super::config::{DEFAULT_HTTP_PORT, DEFAULT_SOCKS_PORT};
use super::connection::ConnectionProfile;
use serde_json::{json, Value};

/// The endpoint is resolved before enabling TUN so its bootstrap never uses the tunnel DNS.
pub fn build_tun_config(profile: &ConnectionProfile) -> Value {
    json!({
        "log": { "level": "warn", "timestamp": true },
        "dns": {
            "servers": [{
                "type": "https", "tag": "remote-dns", "server": "1.1.1.1",
                "tls": { "enabled": true, "server_name": "cloudflare-dns.com" },
                "detour": "proxy"
            }],
            "final": "remote-dns"
        },
        "inbounds": [
            {
                "type": "tun", "tag": "tun-in", "interface_name": "PrivateNetwork",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 1400, "auto_route": true, "strict_route": true,
                "stack": "gvisor"
            },
            { "type": "socks", "listen": "127.0.0.1", "listen_port": DEFAULT_SOCKS_PORT },
            { "type": "http", "listen": "127.0.0.1", "listen_port": DEFAULT_HTTP_PORT }
        ],
        "outbounds": [
            {
                "type": "vless", "tag": "proxy", "server": profile.server_address,
                "server_port": profile.server_port, "uuid": profile.user_id.to_string(),
                "flow": profile.flow.trim_end_matches("-udp443"), "packet_encoding": "xudp",
                "tls": {
                    "enabled": true, "server_name": profile.server_name,
                    "utls": { "enabled": true, "fingerprint": profile.fingerprint },
                    "reality": {
                        "enabled": true, "public_key": profile.reality_password,
                        "short_id": profile.short_id
                    }
                }
            },
            { "type": "direct", "tag": "direct" }
        ],
        "route": {
            "auto_detect_interface": true,
            "rules": [
                { "port": 53, "action": "hijack-dns" },
                { "ip_is_private": true, "outbound": "direct" }
            ],
            "final": "proxy"
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::invite::parse_invitation;

    #[test]
    #[ignore = "requires SING_BOX_TEST_BINARY pointing to the pinned sing-box executable"]
    fn generated_config_passes_sing_box_validation() {
        let profile = parse_invitation("vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=753bd0a1&type=tcp#test").unwrap();
        let file = tempfile::NamedTempFile::new().unwrap();
        serde_json::to_writer(file.as_file(), &build_tun_config(&profile)).unwrap();
        let output = std::process::Command::new(std::env::var_os("SING_BOX_TEST_BINARY").unwrap())
            .arg("check")
            .arg("--config")
            .arg(file.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "sing-box rejected config: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn tunnel_captures_both_ip_families_and_proxies_dns_without_a_routing_loop() {
        let profile = parse_invitation("vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=753bd0a1&type=tcp#test").unwrap();
        let config = build_tun_config(&profile);
        assert_eq!(
            config["inbounds"][0]["address"].as_array().unwrap().len(),
            2
        );
        assert_eq!(config["inbounds"][0]["strict_route"], true);
        assert_eq!(config["inbounds"][0]["stack"], "gvisor");
        assert_eq!(config["route"]["auto_detect_interface"], true);
        assert_eq!(config["dns"]["servers"][0]["detour"], "proxy");
        assert_eq!(config["route"]["rules"][0]["action"], "hijack-dns");
        assert_eq!(config["route"]["final"], "proxy");
        assert_eq!(config["outbounds"][0]["packet_encoding"], "xudp");
        assert!(config["outbounds"][0].get("network").is_none());
    }
}
