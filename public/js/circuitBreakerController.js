var circuitBreakerController = function circuitBreakerController($http) {
    var self = this;
    self.circuitMessage = "Waiting for user input.";
    
    self.openCircuit = function openCircuit() {
        $http.get('/changeCircuit/open')
        .then(function onSuccess(response) {
            self.circuitMessage = "Change successful. The circuit is now open.";
        },
        function onFailure(response) {
            var errStr = 'Failure with error code ' + response.status;
            if (response.data) {
                errStr += ': ' + response.data;
            }
            self.circuitMessage = errStr;
        });
    };
    
    self.closeCircuit = function closeCircuit() {
        $http.get('/changeCircuit/close')
        .then(function onSuccess(response) {
            self.circuitMessage = "Change successful. The circuit is now closed.";
        },
        function onFailure(response) {
            var errStr = 'Failure with error code ' + response.status;
            if (response.data) {
                errStr += ': ' + response.data;
            }
            self.circuitMessage = errStr;
        });
    };

    
    self.checkCircuit = function checkCircuit() {
        $http.get('/checkCircuit/timeout')
        .then(function onSuccess(response) {
            self.circuitMessage = "The circuit is currently closed.";
        },
        function onFailure(response) {
            switch (response.status) {
                case 400:
                    self.circuitMessage = "Bad request: " + response.data;
                    break;
                case 417:
                    self.circuitMessage = "The circuit is currently open.";
                    break;
                case 500:
                    self.circuitMessage = "Internal server error: " + response.data;
                    break;
                default:
                    self.circuitMessage = "Unknown error: " + response.data;
                    break;
            }
        });
    };
};
