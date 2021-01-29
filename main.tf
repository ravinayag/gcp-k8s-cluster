locals {
  worker_nodes = [for i in range(var.num_of_worker_nodes) : format("%s-%d", "worker", i + 1)]

   k8s_ginstance = toset(concat(["master"], local.worker_nodes))

  cni_provider = var.cni_provider == "weavenet" ? (
    "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')") : (
  "https://docs.projectcalico.org/manifests/calico.yaml")

  prereq_script = templatefile("${path.module}/scripts/k8s-cluster-prereq.sh",
  { version = var.k8s_version })
  
  install_script = templatefile("${path.module}/scripts/k8s-cluster-install.sh",
    { pod_cidr     = var.pod_cidr,
      service_cidr = var.service_cidr,
      version      = var.k8s_version,
      cni_provider = local.cni_provider,
      user_name = var.user_name,
      user_pass = var.user_pass,	  
      bucket = var.bucket })

  worker_script = templatefile("${path.module}/scripts/k8s-worker-join.sh",
    { version      = var.k8s_version,
      bucket = var.bucket })
}

resource "google_compute_network" "k8s-vnet-tf" {
  name                    = "k8s-vnet-tf"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet-10-1" {
  name          = "subnet-tf-10-1"
  ip_cidr_range = "10.1.0.0/16"
  region        = var.region
  network       = google_compute_network.k8s-vnet-tf.id
  secondary_ip_range = [{
    ip_cidr_range = var.pod_cidr
    range_name    = "podips"
    },
    {
      ip_cidr_range = var.service_cidr
      range_name    = "serviceips"
  }]
}

resource "google_compute_firewall" "k8s-vnet-fw-external" {
  name    = "k8s-vnet-fw-external"
  network = google_compute_network.k8s-vnet-tf.id
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "30000-40000"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "k8s-vnet-fw-internal" {
  name    = "k8s-vnet-fw-internal"
  network = google_compute_network.k8s-vnet-tf.id
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "ipip"
  }
  source_tags = ["k8s"]
}

resource "google_storage_bucket" "demo-bucket" {
  name = var.bucket
  location = var.region
  storage_class = "regional"  
  force_destroy = true  
}

resource "google_compute_instance" "ginstance" {

  machine_type = var.machine_type
  zone         = var.zone
  for_each                  = local.k8s_ginstance
  name                      = join("-", ["k8s", each.key])
  allow_stopping_for_update = true
  tags = [ "k8s", join("-",["k8s", each.key]) ]
	
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1804-lts"
    }
  }

  network_interface {
    network = google_compute_network.k8s-vnet-tf.id
    subnetwork = google_compute_subnetwork.subnet-10-1.id
    access_config {
      // Ephemeral IP
    }
  }

  metadata_startup_script = each.key == "master" ? join("\n",
    [local.prereq_script, local.install_script]
  ) : join("\n",
    [local.prereq_script, local.worker_script]
  )
  
}