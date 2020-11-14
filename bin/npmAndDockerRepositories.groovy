import groovy.xml.MarkupBuilder
import org.sonatype.nexus.blobstore.api.BlobStoreManager

def newRepositories = []
newRepositories << repository.createNpmProxy("npmjs-org", "https://registry.npmjs.org")

newRepositories << repository.createNpmHosted("npm-internal")

def npmMembers = ["npmjs-org", "npm-internal" ]
newRepositories << repository.createNpmGroup("npm", npmMembers)


// create hosted repo and expose via https to allow deployments
repository.createDockerHosted("docker-internal", null, 4999) 

// create proxy repo of Docker Hub and enable v1 to get search to work
// no ports since access is only indirectly via group
repository.createDockerProxy("docker-hub",                   // name
                             "https://registry-1.docker.io", // remoteUrl
                             "REGISTRY",                          // indexType
                             null,                           // indexUrl
                             null,                           // httpPort
                             null,                           // httpsPort
                             BlobStoreManager.DEFAULT_BLOBSTORE_NAME, // blobStoreName 
                             true, // strictContentTypeValidation
                             true  // v1Enabled
                             )

// create group and allow access via https
def groupMembers = ["docker-hub", "docker-internal"]
repository.createDockerGroup("docker-all", null, 5000, groupMembers, true)

log.info("Script npmAndDockerRepositories completed successfully")

// build up an XML response containing the urls for newly created repositories
def writer = new StringWriter()
def xml = new MarkupBuilder(writer)
xml.repositories() {
  newRepositories.each { repo ->
    repository(name: repo.name, url: repo.url)    
  }  
}
return writer.toString()

// output will be like:
