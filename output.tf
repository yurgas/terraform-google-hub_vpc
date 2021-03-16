output "vpc_id" {
  description = "Hub VPC id"
  value = google_compute_network.vpc.id
}

output "subnet_id" {
  description = "Subnet id in hub VPC"
  value = google_compute_subnetwork.subnet.id
}
