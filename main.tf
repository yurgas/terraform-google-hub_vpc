provider "google" {
  region = var.region
}

resource "google_compute_network" "vpc" {
  name                            = var.vpc_name
  project                         = var.project_id
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = true
  mtu                             = 1500
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.vpc_name}-subnet"
  project       = var.project_id
  ip_cidr_range = var.subnet_range
  region        = var.region
  network       = google_compute_network.vpc.id

  private_ip_google_access = true
}

# Explicit default route for VPC spoke interconnection
resource "google_compute_route" "default" {
  name             = "${var.vpc_name}-default-backup-route"
  project          = var.project_id
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_ip      = cidrhost(var.subnet_range, 1)
  priority         = 10000
}

# NAT instance default route
resource "google_compute_route" "default" {
  name             = "${var.vpc_name}-default-tagged"
  project          = var.project_id
  dest_range       = "0.0.0.0/0"
  network          = google_compute_network.vpc.name
  next_hop_gateway = "default-internet-gateway"
  priority         = 700
  tags             = ["nat-gw"]
}

# Create NAT instance
resource "google_compute_instance" "nat" {
  name         = "${var.vpc_name}-nat-vm"
  project      = var.project_id
  machine_type = "f1-micro"
  zone         = var.zone

  can_ip_forward = true

  tags = ["nat-gw"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-9"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link
    network_ip = cidrhost(var.subnet_range, 4)

    access_config {
      // Ephemeral IP
      network_tier = "STANDARD"
    }
  }

  service_account {
    scopes = ["compute-rw"]
  }

  metadata = {
    "startup-script" = <<SCRIPT
apt-get update
apt-get install dnsutils -y
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
eth0_ip="$(curl -H "Metadata-Flavor:Google" \
http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/ip)"
google_dns1="$(dig +short dns.google | head -n 1)"
google_dns2="$(dig +short dns.google | tail -n 1)"
sudo iptables -t nat -A PREROUTING -p tcp -s 35.191.0.0/16 \
-d $eth0_ip --dport 443 -j DNAT --to $google_dns1
sudo iptables -t nat -A PREROUTING -p tcp -s 130.211.0.0/22 \
-d $eth0_ip --dport 443 -j DNAT --to $google_dns2
vm_hostname="$(curl -H "Metadata-Flavor:Google" \
http://169.254.169.254/computeMetadata/v1/instance/name)"
vm_zone="$(curl -H "Metadata-Flavor:Google" \
http://169.254.169.254/computeMetadata/v1/instance/zone)"
gcloud compute routes create $vm_hostname-route \
    --network hub-vpc --destination-range 0.0.0.0/0 \
    --next-hop-instance $vm_hostname \
    --next-hop-instance-zone $vm_zone --priority 800
SCRIPT

    "shutdown-script" = <<SCRIPT
vm_hostname="$(curl -H "Metadata-Flavor:Google" \
http://169.254.169.254/computeMetadata/v1/instance/name)"
gcloud compute routes delete $vm_hostname-route -q
SCRIPT
  }

}
