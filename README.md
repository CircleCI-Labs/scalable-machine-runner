# Scalable CircleCI Machine Runners with Docker Compose

CircleCI offers two types of runners: Machine Runner and Container Runner. Container Runner has advantages over Machine Runner as it guarantees a clean environment each time by emulating CircleCI's Docker executors operating inside a Docker image. Additionally, Container Runner has built-in scaling for handling multiple requests/jobs at once.

Machine Runner is based on CircleCI Machine executors, but unlike CircleCI's executors, Machine Runners do not guarantee a clean build environment each time. Machine Runner can clean up the working directory, but any files created outside the working directory will persist to subsequent builds. This is a common problem if you are working with system packages like Python. If you install Python at the system level, the next job on that runner will have Python already installed, which might cause issues.

So why not just use Container Runner? It requires a Kubernetes cluster to operate, which can add significant overhead for customers who do not run Kubernetes clusters. 

Is there a way to guarantee clean environments and provide scaling for Machine Runner? Yes, you can create a scalable Machine Runner setup using Docker Compose. With Machine Runner in a Docker container, we can leverage Docker Compose to achieve a clean environment that can scale to meet your needs.

## Docker Compose Setup
In this repo, you will find a working example of a scalable Machine Runner with Docker Compose. Let's break down the Docker Compose file to understand how we can achieve this.

First, by setting CircleCI's Machine Runner mode to `single-task`, the runner agent will accept one job and then quit. Single-task mode is different from the default `continuous` mode, which claims a job, processes it, and then claims a new job.

We can pair single-task mode with Docker Compose's restart policy. If we set the restart policy to `unless-stopped`, Docker Compose will ensure that the service (our Docker image) is always running unless manually stopped.

### Workflow
1. Start the Docker Compose service(s), and CircleCI's runner agent will begin polling CircleCI for jobs.
2. Once a job is claimed, the runner agent processes the job and then quits (due to single-task mode). This causes docker container to exit.
3. Docker Compose detects the stopped service and restarts it, which starts the CircleCI runner agent again. Thus the cycle repeats.

This guarantees that the runner always starts with a clean environment, as any artifacts or files left over from the previous run are deleted when the container exits.

### Scalability
Docker Compose's `replicas` feature allows us to scale by spinning up multiple identical containers for a given service. Normally, a service has a replica of 1, meaning a single container will handle that service's needs. By setting replicas to a value greater than 1, we can run multiple identical containers for a given service.

For example, in our sample `docker-compose.yml`, we use 5 replicas for the `convenience` service, spawning 5 machine runners that can each handle a job simultaneously. This implementation allows you to scale the number of runners easily by setting the replicas value, without the overhead of managing multiple VMs.

## Docker Images
Machine Runner is designed to run on a VM, but it can also run in a container, as supported by CircleCI's official documentation. This repo demonstrates three ways to extend a Docker image to inject the runner agent into your container.

### Base Image
This example extends an Ubuntu image to add the Machine Runner agent, showing how easy it is to extend any Docker image, from an Ubuntu image to a custom image.

### Convenience Image
This example extends a base image, leveraging CircleCI's convenience images, which are maintained by CircleCI and contain common tools for building, testing, and deploying applications.

### Machine Image
This example uses CircleCI's Machine Runner image as the base, which already includes the Machine Runner agent. You only need to install or inject the tools you want to use.

## Other Tips and Tricks
In the `docker-compose.yml`, the `machine` service operates in continuous mode with replicas set to 1, emulating a normal machine runner. This means any files created outside the working directory will persist. Additionally, the runner logs are mounted to the base system, allowing real-time log access and persistence.

This setup demonstrates the flexibility of the Docker Compose implementation, enabling scalable clean runners alongside traditional machine runners in Docker containers.

## Running Scalable CircleCI Machine Runners with Docker Compose

To run the example in your own environment, follow these steps:

1. **Clone the Repository**: 
   - Git clone the GitHub repo to your local system or server.
   
2. **Generate Resource Class and Tokens**:
   - Generate a resource class and token for each service you want to utilize. The example utilizes 3 different Runner resource classes and thus needs 3 runner tokens.

3. **Create Environment Files**:
   - In each service's folder, create a `.env` file with your runner token. By default, the Docker Compose file is looking for the following `.env` files: `base.env`, `convenience.env`, and `machine.env`. 
   - Each `.env` file needs to be formatted like: `CIRCLECI_RUNNER_API_AUTH_TOKEN=YOUR_RUNNER_TOKEN`. Replace `YOUR_RUNNER_TOKEN` with your actual runner token.

4. **Start the Services**:
   - With your services configured and runner tokens set up, run `docker compose up` in the root of the repository.

5. **Verify Runners**:
   - Verify the runners are working by checking CircleCI's self-hosted Runner UI.
