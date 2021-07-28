# This workflow was inspired by https://learn.hashicorp.com/tutorials/terraform/github-actions
name: "Push External Image into AWS ECR"

on:
  # Triggers the workflow on push or pull request events but only for the main branch
  push:
    branches:
      - test
    paths:
      - ""
      - ""
  # Allows you to run this workflow manually from the Actions tab
  workflow_dispatch:

env:
  ...

jobs:
  # This job creates ECR repository for the external image list, if its not already available, and
  # pulls and pushes the external images into Amazon ECR
  migrating-external-images-into-ecr:
    # Strategy creates a build matrix(different variations) for the job.
    strategy:
      matrix:
        accounts: [ "0123456789"]
    runs-on: ubuntu-latest
    env:
      account-number: ${{ matrix.accounts }}
    steps:
      # Configure AWS credential and region environment variables for use in other GitHub Actions
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          ...

      # Checks-out main repository under $GITHUB_WORKSPACE, so the job can access it
      - name: Checking out the repository
        uses: actions/checkout@v2

      # Reads the image config json file that located in image directory
      - name: Reading config file from images/image-config-file.json
        id: readConfigFile
        run: |
          configFile=$(cat ./images/image-config-file.json)
          configFile="${configFile//'%'/'%25'}"
          configFile="${configFile//$'\n'/'%0A'}"
          configFile="${configFile//$'\r'/'%0D'}"
          echo "::set-output name=imageConfigFile::$configFile"

      # Log in to the Amazon Docker Container Registry
      - name: Login to Amazon ECR
        uses: aws-actions/amazon-ecr-login@v1

      - name: Login to aws
        run: |
          aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 602401143452.dkr.ecr.us-west-2.amazonaws.com

      # Creates Docker Container Repository
      - name: Creating ECR Image Registry
        run: |
          appropriateImageList=()
          for image in $(echo "${{ steps.readConfigFile.outputs.imageConfigFile }}" | sed -e 's/[][,]//g' | sed "s/['\"]//g" | xargs ); do
            image=${image%*:*}
            appropriateImageList+=("${{env.account-number}}.dkr.ecr.${{env.aws-region}}.amazonaws.com/${{ github.event.repository.name }}/$image")
          done

          existingImageList=()
          for image in $(echo $(aws ecr describe-repositories --query repositories[*].repositoryUri | sed -e 's/[][,]//g' | sed "s/['\"]//g" | xargs)); do
            existingImageList+=($image)
          done

          imageList=" ${existingImageList[*]} "
          for image in ${appropriateImageList[@]}; do
            if ! [[ $imageList =~ " $image " ]] ; then
              imageCreationList+=($image)
            fi
          done

          imageCreationList=($(echo ${imageCreationList[@]} | tr ' ' '\n' | sort -nu))

          if [ ${#imageCreationList[@]} -gt 0 ]
          then
            echo "Images needs to be created - ${imageCreationList[@]}"
            for image in ${imageCreationList[@]}; do
               echo "Creating Image Repository - ${image}"
               searchString=amazonaws.com/
               image=${image#*$searchString*}
               aws ecr create-repository --repository-name $image --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true
            done
          else
            echo "All Image Repositories are already available"
          fi

      # Pulls and pushes the external image into ECR Repository if its not already there
      - name: Check the tags and publish new image
        run: |
          externalImages=$(echo "${{ steps.readConfigFile.outputs.imageConfigFile }}" | sed -e 's/[][,]//g' | xargs )
          for image in $externalImages; do
            imageName=${image%*:*}
            imageTag=${image#*:*}
            ecrRepositoryName="${{ github.event.repository.name }}/$imageName"
            if [ -n "$ecrRepositoryName" ]
            then
              existingimageTag=$(echo $(aws ecr list-images --repository-name $ecrRepositoryName --query imageIds[*].imageTag --output text | sed -e 's/[][,]//g'))
              tagList=" ${existingimageTag[*]} "
              if [[ $tagList =~ " $imageTag " ]]
              then
                echo "Image Tag ${imageTag} is already present in the list of existing tags in the repository $ecrRepositoryName"
              elif ! [[ $tagList =~ " $imageTag " ]]
              then
                echo "Pulling the Image - $image"
                docker pull $image
                echo "Pulling the image - $image done successfully... Tagging the image - $image to Tagging name - ${{env.account-number}}.dkr.ecr.${{env.aws-region}}.amazonaws.com/${ecrRepositoryName}:$imageTag in progress..."
                docker tag ${image} "${{env.account-number}}.dkr.ecr.${{env.aws-region}}.amazonaws.com/${ecrRepositoryName}:$imageTag"
                echo "Tagging done... Pushing the image - $ecrRepositoryName:$imageTag into the ECR..."
                docker push "${{env.account-number}}.dkr.ecr.${{env.aws-region}}.amazonaws.com/${ecrRepositoryName}:$imageTag"
                echo "Pushing the image - $ecrRepositoryName done successfully..."
              fi
            fi
          done
