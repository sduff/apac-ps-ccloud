# apac-ps-ccloud

Examples of managing [Confluent Cloud](https://confluent.cloud) via the [Confluent Terraform provider](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs)

# How to use this repo

1. Checkout to your workstation
2. Create a file with some resources you want to manage. The filename should be `<yourconfluentusername>_something.tf`
3. Create a branch for your changes (`git checkout -b somebranchname` )
4. `git add`, `git commit`, `git push`
5. Make a Pull Request from your changes. This will trigger a `terraform plan` run in Terraform Cloud. Note this is only a `plan` not an `apply`
6. If no errors, merge your PR and press the button to delete the original branch. You should see your new resources appear in confluent cloud like magic 😎

To delete resources, just delete them from your `.tf` file or delete the `.tf` file. After merging your changes the Confluent Cloud resources will be gone.

# Troubleshooting/logs/CI config

[https://app.terraform.io](https://app.terraform.io)
