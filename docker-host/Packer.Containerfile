FROM hashicorp/packer:1.11.2
RUN packer plugins install github.com/vatesfr/xenserver v0.11.4
