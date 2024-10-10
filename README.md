# tf-aws-infra


this terraform config automatially deployes a VPC within any region that has atleast 3 availability zones 
it creates a VPC and a subnet in 3 separate availability zones with each subnet having 1 private and public ip
all the public ip are assosicated to a public route table and private to a private route table
if any thing in public comes from 0.0.0.0 then it is targeted to an internet gateway

to deploy these infra run these commands

terraform fmt
terraform init
terraform plan
terraform apply

if in the same region we want another deployement of this region 

run 
terraform workspace new (name of workspace)
terraform workspace select (name of workspace)

and run the above commands again 

terraform fmt
terraform init
terraform plan
terraform apply

