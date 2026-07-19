terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
  required_version = ">= 1.0"
}

provider "hcloud" {
  token = var.hcloud_token
}

# SSH key for node access
resource "hcloud_ssh_key" "lattice" {
  name       = "lattice-deploy"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# Firewall: only SSH + P2P
resource "hcloud_firewall" "lattice" {
  name = "lattice-node"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = tostring(var.p2p_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction = "in"
    protocol  = "udp"
    port      = tostring(var.p2p_port)
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Authenticated parent/child fact plane. Restrict source ranges further for
  # a deployment whose child hosts are known in advance.
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "4002"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

# Bootstrap nodes
resource "hcloud_server" "node" {
  count       = length(var.nodes)
  name        = var.nodes[count.index].name
  server_type = var.server_type
  location    = var.nodes[count.index].location
  image       = "ubuntu-22.04"
  ssh_keys    = [hcloud_ssh_key.lattice.id]
  firewall_ids = [hcloud_firewall.lattice.id]

  user_data = templatefile("${path.module}/cloud-init.yml", {
    docker_image = var.image
    p2p_port     = var.p2p_port
  })

  lifecycle {
    # Prevent recreation when cloud-init changes (use provisioner to update instead)
    ignore_changes = [user_data]
  }
}

# Outputs
output "node_ips" {
  description = "Public IPs of bootstrap nodes"
  value = {
    for i, node in hcloud_server.node : var.nodes[i].name => node.ipv4_address
  }
}

output "ssh_commands" {
  description = "SSH commands to access each node"
  value = [
    for i, node in hcloud_server.node : "ssh root@${node.ipv4_address}"
  ]
}

output "peer_flags" {
  description = "Peer flags for connecting to the bootstrap network"
  value = [
    for i, node in hcloud_server.node :
    "--peer <pubkey>@${node.ipv4_address}:${var.p2p_port}"
  ]
}

output "connect_peers_script" {
  description = "Run this after deploy to connect nodes to each other via lattice-update"
  value = join("\n", [
    for i, node in hcloud_server.node :
    "ssh root@${node.ipv4_address} 'lattice-update ${join(" ", [
      for j, peer in hcloud_server.node :
      "--peer <pubkey>@${peer.ipv4_address}:${var.p2p_port}" if j != i
    ])}'"
  ])
}
