provider "aws" {
  region = "ap-south-1"
}

resource "random_id" "id" {
  byte_length = 4
}

resource "aws_s3_bucket" "artifact_bucket" {
  bucket = "codepipeline-artifact-${random_id.id.hex}"
  force_destroy = true
}

# === ROLES ===
resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "codepipeline_policy_attach" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "codebuild_policy_attach" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "codedeploy_role" {
  name = "codedeploy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "codedeploy.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "codedeploy_policy_attach" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "ec2_role" {
  name = "codedeploy-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ec2_policy_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "codedeploy-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# === LAUNCH TEMPLATE + ASG ===
resource "aws_launch_template" "lt" {
  name_prefix   = "codedeploy-lt-"
  image_id      = "ami-0f58b397bc5c1f2e8" # Amazon Linux 2 in ap-south-1
  instance_type = "t2.micro"

  key_name = "tf-test" # <<< Change this
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "codedeploy-asg-instance"
    }
  }

  user_data = base64encode(<<EOF
#!/bin/bash
yum update -y
yum install ruby wget -y
cd /home/ec2-user
wget https://aws-codedeploy-ap-south-1.s3.ap-south-1.amazonaws.com/latest/install
chmod +x ./install
./install auto
systemctl start codedeploy-agent
EOF
  )
}

resource "aws_autoscaling_group" "asg" {
  name                 = "codedeploy-asg"
  desired_capacity     = 1
  max_size             = 1
  min_size             = 1
  vpc_zone_identifier  = ["subnet-0bb8f87334a2d6bcc", "subnet-0343a7202643235b2"] # <<< Replace with your subnet IDs

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "codedeploy-asg-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# === CODEBUILD ===
resource "aws_codebuild_project" "build_project" {
  name         = "my-codebuild-project"
  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    type     = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

# === CODEDEPLOY ===
resource "aws_codedeploy_app" "codedeploy_app" {
  name             = "codedeploy-app"
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "deployment_group" {
  app_name              = aws_codedeploy_app.codedeploy_app.name
  deployment_group_name = "codedeploy-group"
  service_role_arn      = aws_iam_role.codedeploy_role.arn

  deployment_style {
    deployment_type   = "IN_PLACE"
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
  }

  auto_scaling_groups = [aws_autoscaling_group.asg.name]
}

# === CODEPIPELINE ===
resource "aws_codepipeline" "pipeline" {
  name     = "my-demo-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub_Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner      = "BhaktaBS2003"
        Repo       = "task1"
        Branch     = "main"
        OAuthToken = var.github_token
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build_Action"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build_project.name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy_Action"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ApplicationName     = aws_codedeploy_app.codedeploy_app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.deployment_group_name
      }
    }
  }
}
