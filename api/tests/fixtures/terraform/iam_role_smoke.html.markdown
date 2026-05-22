---
subcategory: "IAM (Identity & Access Management)"
layout: "aws"
page_title: "AWS: aws_iam_role"
description: |-
  Provides an IAM role.
---

# Resource: aws_iam_role

Provides an IAM role.

## Example Usage

### Basic Example

```terraform
resource "aws_iam_role" "test_role" {
  name = "test_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    tag-key = "tag-value"
  }
}
```

## Argument Reference

This resource supports the following arguments:

* `assume_role_policy` - (Required) Policy that grants an entity permission to assume the role.
  This is the trust policy. Use `jsonencode` to inline the JSON document.
* `name` - (Optional, Forces new resource) Friendly name of the role.
* `description` - (Optional) Description of the role.
* `max_session_duration` - (Optional) Maximum session duration (in seconds) that you want to set for the specified role. If unset, the default maximum of one hour is applied.
