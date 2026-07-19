variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for node access"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "nodes" {
  description = "Bootstrap node configurations"
  type = list(object({
    name     = string
    location = string
  }))
  default = [
    { name = "bootstrap-1", location = "ash" },   # Ashburn, US-East
    { name = "bootstrap-2", location = "fsn1" },   # Falkenstein, EU
    { name = "bootstrap-3", location = "hil" },    # Hillsboro, US-West
  ]
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cpx11" # 2 vCPU, 2GB RAM, 40GB — $4.50/mo
}

variable "image" {
  description = "Docker image to deploy"
  type        = string
  default     = "ghcr.io/adalinxx/lattice-node:main"
}

variable "p2p_port" {
  description = "P2P listen port"
  type        = number
  default     = 4001
}
